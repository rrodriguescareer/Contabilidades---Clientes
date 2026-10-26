-- Quando o travão impede o self-service, o caso passa a ser do gabinete.
--
-- Duas correções a defeitos reais encontrados a testar isto:
--
-- 1. O alerta não pode ser escrito dentro da função que recusa: o raise
--    desfaz a transação e leva o insert com ele. As funções passam a recusar
--    com um código próprio (P0003) e quem chama regista o alerta já fora da
--    transação abortada.
--
-- 2. task_alerts.person_id era obrigatório, e um conflito de NIF é detetado
--    antes de existir a ficha da pessoa. Os inserts falhavam — e falhavam em
--    silêncio, porque quem os chamava não olhava para o erro.
begin;

alter table public.task_alerts alter column person_id drop not null;

create or replace function public.marcar_conflito_para_o_gabinete(motivo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  select account_id into conta from public.account_access
   where user_id = auth.uid() order by role limit 1;
  if conta is null then return; end if;
  -- Um alerta por conta: repetir a tentativa não enche a fila.
  if exists(select 1 from public.task_alerts
             where account_id = conta and kind = 'nif_bloqueado' and resolved_at is null) then
    return;
  end if;
  insert into public.task_alerts(account_id, kind) values (conta, 'nif_bloqueado');
end $$;

create or replace function public.apagar_conta_do_nif(contribuinte text, confirmacao text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  alvo uuid;
  conta uuid;
  apagados jsonb;
  ficheiros text[];
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'APAGAR' then raise exception 'Falta a confirmacao.'; end if;
  if contribuinte !~ '^[0-9]{9}$' then raise exception 'NIF invalido.'; end if;

  select id into alvo from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;
  if alvo is null then raise exception 'Nao ha conta anterior com este NIF.'; end if;

  select a.account_id into conta from public.account_access a
   where a.user_id = alvo order by a.role limit 1;
  if conta is null then raise exception 'Conta anterior nao encontrada.'; end if;

  -- Travão: histórico a sério não se apaga sozinho.
  if exists(
    select 1 from public.irs_cases c
     where c.account_id = conta
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'Conta anterior com processo submetido ou pago.' using errcode = 'P0003';
  end if;

  select coalesce(array_agg(d.storage_path), array[]::text[]) into ficheiros
    from public.documents d where d.account_id = conta;

  apagados := jsonb_build_object(
    'rendimentos', (select count(*) from public.income_records where account_id = conta),
    'documentos', (select count(*) from public.documents where account_id = conta),
    'pessoas', (select count(*) from public.people where account_id = conta),
    'processos', (select count(*) from public.irs_cases where account_id = conta));

  delete from public.document_downloads where account_id = conta;
  delete from public.documents where account_id = conta;
  delete from public.income_records where account_id = conta;
  delete from public.case_notes where account_id = conta;
  delete from public.case_deductions where account_id = conta;
  delete from public.property_assets where account_id = conta;
  delete from public.messages where account_id = conta;
  delete from public.progress_events where account_id = conta;
  delete from public.irs_checkouts where account_id = conta;
  delete from public.task_alerts where account_id = conta;
  delete from public.household_invitations where account_id = conta;
  delete from public.invitation_requests where account_id = conta;
  delete from public.tax_credential_views where account_id = conta;
  delete from public.tax_credentials where account_id = conta;
  delete from public.case_people where account_id = conta;
  delete from public.people where account_id = conta;
  delete from public.irs_cases where account_id = conta;
  delete from public.account_access where account_id = conta;
  delete from public.client_accounts where id = conta;

  -- O utilizador em si fica marcado como eliminado: apagar a conta Auth
  -- pertence à administração, não a esta função.
  update public.profiles set deleted_at = now(), nif = null where id = alvo;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, alvo, 'nif_conta_apagada');

  return jsonb_build_object('apagados', apagados, 'ficheiros', to_jsonb(ficheiros));
end $$;

/* A migração sai de um agregado alheio para conta própria.
   Primeiro passo: diz o que há para mover, sem mover nada. */
create or replace function public.preparar_migracao_do_agregado(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'Agregado com processo submetido ou pago.' using errcode = 'P0003';
  end if;

  return jsonb_build_object(
    'pessoa', pessoa.id,
    'processo_antigo', pessoa.case_id,
    'relacao', pessoa.relationship,
    'rendimentos', (select count(*) from public.income_records
                     where case_id = pessoa.case_id and person_id = pessoa.id),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'caminho', d.storage_path, 'nome', d.file_name, 'tipo', d.kind,
        'categoria', d.category, 'descricao', d.description, 'mime', d.mime_type,
        'tamanho', d.file_size, 'hash', d.content_hash, 'rendimento', d.income_id)), '[]'::jsonb)
      from public.documents d
      join public.income_records ir on ir.id = d.income_id
      where ir.case_id = pessoa.case_id and ir.person_id = pessoa.id));
end $$;

commit;
