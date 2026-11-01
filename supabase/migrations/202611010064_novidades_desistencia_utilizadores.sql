-- Novidades, utilizadores e desistência.
--
-- 1. Novidades: cada pessoa marca quando viu cada área (o acompanhamento, os
--    pagamentos, os documentos de uma empresa…). Os menus dos três portais
--    mostram um número no que mudou desde então.
-- 2. Gestão: os clientes registados e validados há mais de sete dias que ainda
--    não pagaram aparecem como alerta; e as contagens do menu passam a incluir
--    as empresas, os pagamentos novos, esses clientes e as desistências.
-- 3. Eliminar utilizadores: também os contabilistas da equipa (o titular do
--    gabinete nunca), e o que ficou ligado a eles nas tabelas novas.
-- 4. Pedido de desistência do serviço de IRS, feito pelo cliente em «A minha
--    conta» e decidido pelo contabilista. Fica registado se foi feito dentro
--    dos 14 dias de livre resolução.
begin;

-- ------------------------------------------------------------ novidades
create table public.ultimas_vistas (
  user_id uuid not null,
  area text not null check (area ~ '^[a-z0-9:-]{1,120}$'),
  visto_em timestamptz not null default now(),
  primary key (user_id, area)
);
alter table public.ultimas_vistas enable row level security;
revoke all on public.ultimas_vistas from anon, authenticated;
grant select on public.ultimas_vistas to authenticated;
create policy ultimas_vistas_ler on public.ultimas_vistas for select to authenticated
  using (user_id = (select auth.uid()));

create function public.marcar_visto(p_area text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or coalesce(p_area, '') !~ '^[a-z0-9:-]{1,120}$' then return; end if;
  insert into public.ultimas_vistas(user_id, area) values (auth.uid(), p_area)
  on conflict (user_id, area) do update set visto_em = now();
end $$;

create function public.visto_em(p_area text) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select v.visto_em from public.ultimas_vistas v where v.user_id = auth.uid() and v.area = p_area
$$;

-- ------------------------------------------------------------ desistência
create table public.pedidos_desistencia (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  case_id uuid not null references public.irs_cases(id) on delete cascade,
  user_id uuid not null,
  motivo text check (motivo is null or length(motivo) <= 2000),
  contratado_em timestamptz not null,
  dentro_do_prazo boolean not null,
  estado text not null default 'pendente' check (estado in ('pendente', 'aceite', 'recusado', 'anulado')),
  resposta text check (resposta is null or length(resposta) <= 2000),
  criado_em timestamptz not null default now(),
  tratado_em timestamptz,
  tratado_por uuid
);
create unique index pedidos_desistencia_um_pendente on public.pedidos_desistencia(case_id) where estado = 'pendente';
create index pedidos_desistencia_conta on public.pedidos_desistencia(account_id, criado_em desc);
alter table public.pedidos_desistencia enable row level security;
revoke all on public.pedidos_desistencia from anon, authenticated;
grant select on public.pedidos_desistencia to authenticated;
create policy pedidos_desistencia_ler on public.pedidos_desistencia for select to authenticated
  using (public.can_read_account(account_id) or (select public.is_staff()));

/* O cliente pede. Só o titular da conta, e só enquanto o processo não está
   fechado. O prazo de livre resolução conta-se do pagamento da preparação
   (o momento em que o contrato fica fechado); sem pagamento, da abertura. */
create function public.pedir_desistencia(processo uuid, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.irs_cases; contrato timestamptz; dentro boolean; novo uuid; v_motivo text := nullif(left(btrim(coalesce(p_motivo, '')), 2000), '');
begin
  select * into c from public.irs_cases where id = processo for update;
  if not found or auth.uid() is null or not exists (
       select 1 from public.account_access a
        where a.account_id = c.account_id and a.user_id = auth.uid() and a.role = 'owner' and a.active) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if c.status = 'closed' then raise exception 'Processo já concluído' using errcode = '22023'; end if;
  if exists (select 1 from public.pedidos_desistencia p where p.case_id = processo and p.estado = 'pendente') then
    raise exception 'Já existe um pedido pendente' using errcode = '23505';
  end if;
  select coalesce(min(k.paid_at), c.created_at) into contrato
    from public.irs_checkouts k where k.case_id = processo and k.tipo = 'preparacao' and k.state = 'paid';
  contrato := coalesce(contrato, c.created_at);
  dentro := now() <= contrato + interval '14 days';
  insert into public.pedidos_desistencia(account_id, case_id, user_id, motivo, contratado_em, dentro_do_prazo)
  values (c.account_id, c.id, auth.uid(), v_motivo, contrato, dentro) returning id into novo;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (c.account_id, c.id, auth.uid(), 'Pedido de desistência',
          'O pedido de desistência foi recebido e vai ser analisado pelo contabilista.'
          || case when dentro then ' Foi feito dentro do prazo de 14 dias de livre resolução.' else '' end);
  insert into public.task_alerts(account_id, kind) values (c.account_id, 'desistencia');
  return jsonb_build_object('id', novo, 'dentro_do_prazo', dentro, 'contratado_em', contrato);
end $$;

create function public.anular_desistencia(pedido uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.pedidos_desistencia;
begin
  select * into p from public.pedidos_desistencia where id = pedido for update;
  if not found or p.user_id is distinct from auth.uid() then raise exception 'Not authorized' using errcode = '42501'; end if;
  if p.estado <> 'pendente' then raise exception 'O pedido já foi tratado' using errcode = '22023'; end if;
  update public.pedidos_desistencia set estado = 'anulado', tratado_em = now(), tratado_por = auth.uid() where id = p.id;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (p.account_id, p.case_id, auth.uid(), 'Pedido de desistência anulado', 'O pedido de desistência foi anulado. O processo continua.');
  update public.task_alerts set resolved_at = now() where account_id = p.account_id and kind = 'desistencia' and resolved_at is null;
end $$;

/* O contabilista decide. Aceite, o processo fecha; o reembolso, se houver,
   faz-se no separador de pagamentos do processo, como os outros. */
create function public.tratar_desistencia(pedido uuid, p_aceite boolean, p_resposta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.pedidos_desistencia; v_resposta text := nullif(left(btrim(coalesce(p_resposta, '')), 2000), '');
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into p from public.pedidos_desistencia where id = pedido for update;
  if not found then raise exception 'Pedido desconhecido' using errcode = '22023'; end if;
  if p.estado <> 'pendente' then raise exception 'O pedido já foi tratado' using errcode = '22023'; end if;
  update public.pedidos_desistencia
     set estado = case when p_aceite then 'aceite' else 'recusado' end, resposta = v_resposta,
         tratado_em = now(), tratado_por = auth.uid()
   where id = p.id;
  if p_aceite then
    update public.irs_cases set status = 'closed', status_changed_at = now() where id = p.case_id;
  end if;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (p.account_id, p.case_id, auth.uid(),
          case when p_aceite then 'Desistência aceite' else 'Pedido de desistência recusado' end,
          coalesce(v_resposta, case when p_aceite then 'O processo foi encerrado a seu pedido.' else 'O processo continua.' end));
  update public.task_alerts set resolved_at = now() where account_id = p.account_id and kind = 'desistencia' and resolved_at is null;
end $$;

-- ------------------------------------------------------------ o que é novo
create function public.novidades_irs(processo uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.irs_cases;
begin
  select * into c from public.irs_cases where id = processo;
  if not found or not public.can_read_account(c.account_id) then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'progresso', (select count(*) from public.progress_events e
                   where e.case_id = processo and e.author_id is distinct from auth.uid()
                     and e.created_at > coalesce(public.visto_em('irs:progresso:' || processo), '-infinity'::timestamptz)),
    'pagamento', (select count(*) from public.irs_checkouts k
                   where k.case_id = processo and k.tipo = 'extra' and k.state in ('creating', 'pending', 'unknown', 'failed'))
               + (select count(*) from public.reembolsos r
                   where r.case_id = processo and r.criado_em > coalesce(public.visto_em('irs:pagamento:' || processo), '-infinity'::timestamptz)),
    'documentos', (select count(*) from public.documents d where d.case_id = processo and d.state = 'rejected'),
    'desistencia', (select p.estado from public.pedidos_desistencia p where p.case_id = processo order by p.criado_em desc limit 1));
end $$;

create function public.novidades_empresa(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare hoje date := (now() at time zone 'Europe/Lisbon')::date;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'documentos', (select count(*) from public.empresa_documentos d
                    where d.company_id = empresa and d.estado = 'devolvido'
                      and d.revisto_em > coalesce(public.visto_em('empresas:documentos:' || empresa), '-infinity'::timestamptz)),
    'pessoal', (select count(*) from public.empresa_pessoal p
                 where p.company_id = empresa and p.estado in ('tratado', 'devolvido')
                   and p.tratado_em > coalesce(public.visto_em('empresas:pessoal:' || empresa), '-infinity'::timestamptz))
             + (select count(*) from public.empresa_recibos r
                 where r.company_id = empresa and r.publicado_em > coalesce(public.visto_em('empresas:pessoal:' || empresa), '-infinity'::timestamptz)),
    'prazos', (select count(*) from public.empresa_prazos p
                where (p.company_id = empresa or p.company_id is null) and p.data >= hoje
                  and p.criado_em > coalesce(public.visto_em('empresas:prazos:' || empresa), '-infinity'::timestamptz)),
    'alertas', (select count(*) from public.empresa_alertas a
                 where (a.company_id = empresa or a.company_id is null) and (a.expira_em is null or a.expira_em >= hoje)
                   and not exists (select 1 from public.empresa_alertas_lidos l where l.alerta_id = a.id and l.user_id = auth.uid())));
end $$;

-- ------------------------------------------------- clientes sem pagamento
/* Quem conta: cliente do IRS (não só de empresas), email confirmado há mais
   de N dias, conta ativa, sem serviço gratuito e sem nenhum pagamento. */
create function public.clientes_sem_pagamento(dias integer default 7)
returns table(id uuid, email text, nome text, confirmado_em timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select p.id, p.email, p.full_name, u.email_confirmed_at
    from auth.users u join public.profiles p on p.id = u.id
   where u.email_confirmed_at is not null
     and u.email_confirmed_at < now() - make_interval(days => greatest(dias, 1))
     and p.deleted_at is null and p.disabled_at is null and not coalesce(p.irs_free, false)
     and not exists (select 1 from public.staff_users s where s.user_id = p.id)
     and not exists (select 1 from public.account_access a where a.user_id = p.id and a.business and not a.irs)
     and not exists (select 1 from public.account_access a join public.irs_checkouts k on k.account_id = a.account_id
                      where a.user_id = p.id and k.state = 'paid');
end $$;
revoke all on function public.clientes_sem_pagamento(integer) from public, anon, authenticated;

create function public.sem_pagamento(dias integer default 7) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
            'id', s.id, 'email', s.email, 'nome', s.nome, 'confirmado_em', s.confirmado_em,
            'dias', extract(day from now() - s.confirmado_em)::int) order by s.confirmado_em)
           from public.clientes_sem_pagamento(dias) s), '[]'::jsonb);
end $$;

-- ------------------------------------------------- as contagens da gestão
create or replace function public.contagens_do_gabinete() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not public.is_staff() then '{}'::jsonb else jsonb_build_object(
    'a_rever', (select count(*) from public.irs_cases
                 where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
    'alertas', (select count(*) from public.task_alerts where resolved_at is null),
    'por_responder', (
      select count(*) from public.irs_cases c
       where exists(
         select 1 from public.messages m
          where m.case_id = c.id
            and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
            and m.created_at > coalesce((
              select max(m2.created_at) from public.messages m2
               join public.staff_users s2 on s2.user_id = m2.author_id
               where m2.case_id = c.id), '-infinity'::timestamptz))),
    'pagamentos', (select count(*) from public.irs_checkouts k
                    where k.state = 'paid'
                      and k.paid_at > coalesce(public.visto_em('gestao:pagamentos'), now() - interval '7 days')),
    'sem_pagamento', (select count(*) from public.clientes_sem_pagamento(7)),
    'desistencias', (select count(*) from public.pedidos_desistencia where estado = 'pendente'),
    'empresas', (select count(*) from public.empresa_mensagens m where not m.do_gabinete and m.lida_em is null)
              + (select count(*) from public.empresa_documentos d where d.estado = 'recebido')
              + (select count(*) from public.empresa_pessoal p where p.estado = 'novo')
  ) end
$$;

-- ------------------------------------------------- eliminar utilizadores
/* Também os contabilistas da equipa. O titular do gabinete (o contabilista
   sem gestor) nunca se elimina por aqui. */
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.eliminar_utilizador(uuid)'::regprocedure);
  d := replace(d, $a$  if exists(select 1 from public.staff_users where user_id = target) then
    raise exception 'Uma conta do gabinete não se elimina por aqui.' using errcode = '22023';
  end if;$a$, $a$  if exists(select 1 from public.staff_users where user_id = target and managed_by is null) then
    raise exception 'A conta do titular do gabinete não se elimina por aqui.' using errcode = '22023';
  end if;
  delete from public.staff_users where user_id = target;
  delete from public.ultimas_vistas where user_id = target;
  delete from public.empresa_alertas_lidos where user_id = target;
  delete from public.pedidos_desistencia where user_id = target;$a$);
  if d not like '%titular do gabinete%' then raise exception 'eliminar_utilizador: texto não encontrado'; end if;
  execute d;
end $x$;

-- ------------------------------------------------------- execute
do $x$
declare f text;
begin
  foreach f in array array[
    'public.marcar_visto(text)', 'public.visto_em(text)', 'public.pedir_desistencia(uuid,text)',
    'public.anular_desistencia(uuid)', 'public.tratar_desistencia(uuid,boolean,text)',
    'public.novidades_irs(uuid)', 'public.novidades_empresa(uuid)', 'public.sem_pagamento(integer)',
    'public.contagens_do_gabinete()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;

commit;
