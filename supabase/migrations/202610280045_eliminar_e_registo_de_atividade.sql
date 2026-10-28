-- 1. Eliminar um utilizador por completo.
--    A eliminação antiga só bloqueava o acesso e anonimizava o perfil: os
--    processos, rendimentos, documentos, mensagens e pagamentos ficavam na
--    base. Agora apaga-se tudo o que é da conta de que o utilizador é titular
--    (e o que ele próprio escreveu noutras), quer tenha confirmado o email quer
--    não. Os ficheiros saem do armazenamento pelo servidor (o Storage não deixa
--    apagar por SQL); a autenticação sai pela API de administração. A ficha no
--    Cegid não é tocada: vive lá e é lá que se gere.
--
-- 2. Registo de atividade, para prova numa contestação de pagamento: entradas
--    na conta (com IP e browser), início do pagamento, confirmação pelo Stripe,
--    ficha e fatura no Cegid — o que até aqui não ficava guardado em lado
--    nenhum.
--
-- 3. relatorio_de_atividade: a linha do tempo completa de um processo, com
--    tudo o que a base sabe, numa consulta só.
begin;

-- ------------------------------------------------------ registo de atividade
create table if not exists public.registo_atividade (
  id bigint generated always as identity primary key,
  user_id uuid,
  account_id uuid,
  case_id uuid,
  tipo text not null check (length(tipo) between 2 and 60),
  detalhe text check (detalhe is null or length(detalhe) <= 2000),
  ip text check (ip is null or length(ip) <= 64),
  agente text check (agente is null or length(agente) <= 400),
  criado_em timestamptz not null default now()
);
create index if not exists registo_atividade_conta_idx on public.registo_atividade(account_id, criado_em);
create index if not exists registo_atividade_user_idx on public.registo_atividade(user_id, criado_em);
alter table public.registo_atividade enable row level security;
-- Sem políticas: ninguém lê nem escreve diretamente. Escreve-se pela função
-- abaixo (o próprio utilizador) ou pela chave de serviço (o sistema).

create or replace function public.registar_atividade(
  p_tipo text, p_detalhe text default null, p_case uuid default null,
  p_ip text default null, p_agente text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then return; end if;
  if p_case is not null then
    select account_id into conta from public.irs_cases where id = p_case;
    if conta is null or not public.can_read_account(conta) then return; end if;
  else
    select a.account_id into conta from public.account_access a
     where a.user_id = auth.uid() and a.role = 'owner' limit 1;
  end if;
  insert into public.registo_atividade(user_id, account_id, case_id, tipo, detalhe, ip, agente)
  values (auth.uid(), conta, p_case, left(p_tipo, 60), left(p_detalhe, 2000), left(p_ip, 64), left(p_agente, 400));
end $$;

revoke all on function public.registar_atividade(text,text,uuid,text,text) from public, anon;
grant execute on function public.registar_atividade(text,text,uuid,text,text) to authenticated;

-- ------------------------------------------------------------- eliminação
create or replace function public.eliminar_utilizador(target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  contas uuid[];
  caminhos text[];
  pago boolean;
begin
  if not public.is_platform_owner() or target = auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if exists(select 1 from public.staff_users where user_id = target) then
    raise exception 'Uma conta do gabinete não se elimina por aqui.' using errcode = '22023';
  end if;

  -- As contas de que é titular saem por inteiro.
  select coalesce(array_agg(account_id), '{}') into contas
    from public.account_access where user_id = target and role = 'owner';

  select exists(select 1 from public.irs_checkouts where account_id = any(contas) and state = 'paid') into pago;

  select coalesce(array_agg(storage_path), '{}') into caminhos
    from public.documents where account_id = any(contas) or uploaded_by = target;

  -- Primeiro os pagamentos: com um pagamento aberto, o gatilho da recolha
  -- recusaria apagar rendimentos e documentos.
  delete from public.irs_checkouts where account_id = any(contas) or user_id = target;
  delete from public.documents where account_id = any(contas) or uploaded_by = target;
  delete from public.income_records where account_id = any(contas);
  delete from public.property_assets where account_id = any(contas);
  delete from public.case_notes where account_id = any(contas);
  delete from public.case_deductions where account_id = any(contas);
  delete from public.messages where account_id = any(contas) or author_id = target;
  delete from public.progress_events where account_id = any(contas) or author_id = target;
  delete from public.task_alerts where account_id = any(contas);
  delete from public.invitation_requests where account_id = any(contas) or requested_by = target;
  delete from public.household_invitations where account_id = any(contas);
  update public.household_invitations set accepted_by = null where accepted_by = target;
  delete from public.tax_credential_views where account_id = any(contas);
  delete from public.tax_credentials where account_id = any(contas);
  delete from public.case_people where account_id = any(contas);
  delete from public.people where account_id = any(contas);
  delete from public.irs_cases where account_id = any(contas);
  delete from public.payments where account_id = any(contas);
  delete from public.invoices where account_id = any(contas);
  delete from public.registo_atividade where account_id = any(contas) or user_id = target;
  delete from public.account_access where account_id = any(contas) or user_id = target;
  delete from public.client_accounts where id = any(contas);

  -- O que aponta para o perfil e impediria apagar a autenticação.
  delete from public.company_users where user_id = target;
  update public.staff_users set managed_by = null where managed_by = target;
  update public.profiles set forced_discount_id = null where id = target;
  delete from public.discount_codes d where d.allowed_user = target
     and not exists(select 1 from public.irs_checkouts k where k.discount_id = d.id)
     and not exists(select 1 from public.profiles p where p.forced_discount_id = d.id);
  update public.discount_codes set allowed_user = null, active = false where allowed_user = target;

  -- O perfil sai aqui (e não só em cascata da autenticação): serve também
  -- para limpar contas que a eliminação antiga deixou anonimizadas.
  delete from public.profiles where id = target;

  insert into public.management_audit(actor_id, target_id, action)
    values (auth.uid(), target, 'user_fully_deleted');

  return jsonb_build_object('caminhos', to_jsonb(caminhos), 'contas', cardinality(contas), 'tinha_pagamento', pago);
end $$;

revoke all on function public.eliminar_utilizador(uuid) from public, anon;
grant execute on function public.eliminar_utilizador(uuid) to authenticated;

-- Para a confirmação: o que vai ser apagado, e se houve pagamento (uma
-- contestação pode chegar até 120 dias depois).
create or replace function public.antes_de_eliminar(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with contas as (
    select account_id from public.account_access where user_id = target and role = 'owner')
  select case when not public.is_platform_owner() then '{}'::jsonb else jsonb_build_object(
    'confirmado', (select u.email_confirmed_at is not null from auth.users u where u.id = target),
    'processos', (select count(*) from public.irs_cases where account_id in (select account_id from contas)),
    'rendimentos', (select count(*) from public.income_records where account_id in (select account_id from contas)),
    'documentos', (select count(*) from public.documents where account_id in (select account_id from contas)),
    'mensagens', (select count(*) from public.messages where account_id in (select account_id from contas)),
    'pago_em', (select max(paid_at) from public.irs_checkouts where account_id in (select account_id from contas) and state = 'paid'),
    'processo', (select c.id from public.irs_cases c where c.account_id in (select account_id from contas) order by c.tax_year desc limit 1)
  ) end
$$;

revoke all on function public.antes_de_eliminar(uuid) from public, anon;
grant execute on function public.antes_de_eliminar(uuid) to authenticated;

-- ------------------------------------------------- relatório de atividade
create or replace function public.relatorio_de_atividade(processo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conta uuid;
  titular uuid;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then raise exception 'Processo não encontrado.' using errcode = '22023'; end if;
  select user_id into titular from public.account_access
   where account_id = conta and role = 'owner' limit 1;

  return jsonb_build_object(
    'cliente', (
      select jsonb_build_object(
        'nome', p.full_name, 'nif', p.nif, 'email', coalesce(nullif(p.email, ''), u.email),
        'telefone', p.phone, 'morada', p.address, 'nascimento', p.birth_date,
        'conta_criada', u.created_at, 'email_confirmado', u.email_confirmed_at,
        'ultimo_acesso', u.last_sign_in_at, 'utilizador', p.id)
      from public.profiles p left join auth.users u on u.id = p.id
      where p.id = titular),
    'processo', (
      select jsonb_build_object('id', c.id, 'ano', c.tax_year, 'estado', c.status,
        'aberto', c.created_at, 'submetido', c.submitted_by_client_at,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
      from public.irs_cases c where c.id = processo),
    'pagamentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', k.id, 'estado', k.state, 'total', k.amount_cents, 'desconto', k.discount_cents,
        'criado', k.created_at, 'pago_em', k.paid_at, 'sessao', k.provider_order_id, 'detalhe', k.quote)
        order by k.created_at), '[]'::jsonb)
      from public.irs_checkouts k where k.case_id = processo),
    'eventos', (
      select coalesce(jsonb_agg(e order by e->>'em', e->>'ordem'), '[]'::jsonb) from (
        select jsonb_build_object('em', u.created_at, 'ordem', '01', 'origem', 'Cliente',
               'evento', 'Conta criada na plataforma', 'detalhe', u.email) e
          from auth.users u where u.id = titular
        union all
        select jsonb_build_object('em', u.email_confirmed_at, 'ordem', '02', 'origem', 'Cliente',
               'evento', 'Email confirmado', 'detalhe', 'Através da ligação enviada para ' || u.email)
          from auth.users u where u.id = titular and u.email_confirmed_at is not null
        union all
        select jsonb_build_object('em', l.accepted_at, 'ordem', '03', 'origem', 'Cliente',
               'evento', 'Termos e Condições e Política de Privacidade aceites',
               'detalhe', 'Versão ' || l.terms_version || coalesce(' · ' || l.source, ''))
          from public.legal_acceptances l where l.user_id = titular
        union all
        select jsonb_build_object('em', p.onboarding_completed_at, 'ordem', '04', 'origem', 'Cliente',
               'evento', 'Dados pessoais preenchidos',
               'detalhe', concat_ws(' · ', p.full_name, 'NIF ' || p.nif, p.phone, p.address))
          from public.profiles p where p.id = titular and p.onboarding_completed_at is not null
        union all
        select jsonb_build_object('em', c.created_at, 'ordem', '05', 'origem', 'Sistema',
               'evento', 'Processo de IRS ' || c.tax_year || ' aberto', 'detalhe', 'Processo ' || c.id)
          from public.irs_cases c where c.id = processo
        union all
        select jsonb_build_object('em', pe.created_at, 'ordem', '06', 'origem', 'Cliente',
               'evento', 'Pessoa do agregado registada',
               'detalhe', concat_ws(' · ', pe.full_name, 'NIF ' || pe.nif, cp.relationship))
          from public.case_people cp join public.people pe on pe.id = cp.person_id
         where cp.case_id = processo
        union all
        select jsonb_build_object('em', tc.updated_at, 'ordem', '07', 'origem', 'Cliente',
               'evento', 'Senha do Portal das Finanças guardada (cifrada)', 'detalhe', pe.full_name)
          from public.tax_credentials tc join public.people pe on pe.id = tc.person_id
         where tc.account_id = conta
        union all
        select jsonb_build_object('em', ir.created_at, 'ordem', '08', 'origem', 'Cliente',
               'evento', 'Rendimento declarado',
               'detalhe', concat_ws(' · ', coalesce(ir.kind, ir.title), ir.category,
                 (select pe.full_name from public.people pe where pe.id = ir.person_id),
                 case when ir.amount_cents is not null then to_char(ir.amount_cents / 100.0, 'FM999G999G990D00') || ' €' end))
          from public.income_records ir where ir.case_id = processo
        union all
        select jsonb_build_object('em', d.created_at, 'ordem', '09', 'origem', 'Cliente',
               'evento', 'Documento enviado',
               'detalhe', concat_ws(' · ', d.kind, d.description, d.file_name, round(d.file_size / 1024.0) || ' KB'))
          from public.documents d where d.case_id = processo
        union all
        select jsonb_build_object('em', k.created_at, 'ordem', '10', 'origem', 'Cliente',
               'evento', 'Pagamento iniciado',
               'detalhe', to_char(k.amount_cents / 100.0, 'FM999G990D00') || ' € · tentativa ' || k.id)
          from public.irs_checkouts k where k.case_id = processo
        union all
        select jsonb_build_object('em', k.paid_at, 'ordem', '11', 'origem', 'Stripe',
               'evento', 'Pagamento confirmado',
               'detalhe', to_char(k.amount_cents / 100.0, 'FM999G990D00') || ' € · sessão ' || coalesce(k.provider_order_id, '—'))
          from public.irs_checkouts k where k.case_id = processo and k.state = 'paid' and k.paid_at is not null
        union all
        select jsonb_build_object('em', coalesce(k.last_checked_at, k.created_at), 'ordem', '12', 'origem', 'Stripe',
               'evento', case k.state when 'failed' then 'Pagamento falhado ou expirado' else 'Pagamento cancelado' end,
               'detalhe', 'Tentativa ' || k.id)
          from public.irs_checkouts k where k.case_id = processo and k.state in ('failed','cancelled')
        union all
        select jsonb_build_object('em', ev.created_at, 'ordem', '13',
               'origem', case when exists(select 1 from public.staff_users s where s.user_id = ev.author_id) then 'Contabilista' else 'Cliente' end,
               'evento', ev.title, 'detalhe', ev.body)
          from public.progress_events ev where ev.case_id = processo
        union all
        select jsonb_build_object('em', m.created_at, 'ordem', '14',
               'origem', case when exists(select 1 from public.staff_users s where s.user_id = m.author_id) then 'Contabilista' else 'Cliente' end,
               'evento', case when exists(select 1 from public.staff_users s where s.user_id = m.author_id)
                              then 'Mensagem enviada ao cliente' else 'Mensagem enviada ao contabilista' end,
               'detalhe', '"' || left(m.body, 600) || '"')
          from public.messages m where m.case_id = processo
        union all
        select jsonb_build_object('em', dd.downloaded_at, 'ordem', '15', 'origem', 'Contabilista',
               'evento', 'Documento aberto pelo contabilista',
               'detalhe', concat_ws(' · ', d.kind, d.description, d.file_name))
          from public.document_downloads dd join public.documents d on d.id = dd.document_id
         where d.case_id = processo
        union all
        select jsonb_build_object('em', v.viewed_at, 'ordem', '16', 'origem', 'Contabilista',
               'evento', 'Senha do Portal das Finanças consultada', 'detalhe', pe.full_name)
          from public.tax_credential_views v join public.people pe on pe.id = v.person_id
         where v.account_id = conta
        union all
        select jsonb_build_object('em', r.criado_em, 'ordem', '17',
               'origem', case
                 when r.tipo like 'cegid%' then 'Cegid Business'
                 when r.tipo like 'stripe%' then 'Stripe'
                 when r.user_id is not null and exists(select 1 from public.staff_users s where s.user_id = r.user_id) then 'Contabilista'
                 when r.user_id is null then 'Sistema'
                 else 'Cliente' end,
               'evento', case r.tipo
                 when 'login' then 'Entrada na conta'
                 when 'registo' then 'Registo submetido'
                 when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'stripe_evento' then 'Notificação do Stripe recebida'
                 when 'cegid_ficha' then 'Ficha de cliente criada no Cegid Business'
                 when 'cegid_ficha_falhou' then 'Criação da ficha no Cegid recusada'
                 when 'cegid_fatura' then 'Fatura-recibo criada no Cegid Business'
                 else r.tipo end,
               'detalhe', concat_ws(' · ', r.detalhe, 'IP ' || r.ip, r.agente))
          from public.registo_atividade r
         where r.account_id = conta or (r.user_id = titular and r.account_id is null)
      ) t where e->>'em' is not null)
  );
end $$;

revoke all on function public.relatorio_de_atividade(uuid) from public, anon;
grant execute on function public.relatorio_de_atividade(uuid) to authenticated;

commit;
