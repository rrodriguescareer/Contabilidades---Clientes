-- Autenticação de dois fatores (aplicação de autenticação, TOTP do Supabase)
-- no portal do IRS e no portal Empresas.
--
-- 1. Quem tem um fator verificado só vê dados com uma sessão que passou o
--    segundo fator (aal2). A regra vive na base, não só nas aplicações:
--    uma política restritiva em todas as tabelas e no Storage, e as funções de
--    acesso do cliente (can_read_account, pode_aceder_empresa) exigem o
--    mesmo. Quem não tem fator nenhum continua como estava.
-- 2. O contexto de cada portal diz se falta o segundo fator, para a aplicação
--    pedir o código em vez de mostrar um ecrã vazio.
-- 3. A pergunta «quer ativar?» depois da entrada pode ser dispensada.
-- 4. Códigos por email (para desativar o segundo fator): só o servidor os lê
--    e escreve, guardados como resumo, com validade e tentativas contadas.
-- 5. A gestão vê quem tem o segundo fator ativo.
begin;

create function public.aal_suficiente() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f
                      where f.user_id = (select auth.uid()) and f.status = 'verified')
$$;
revoke all on function public.aal_suficiente() from public, anon;
grant execute on function public.aal_suficiente() to authenticated, service_role;

-- As funções de acesso do cliente.
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.can_read_account(uuid)'::regprocedure);
  d := replace(d, $a$select public.is_staff() or (public.user_enabled((select auth.uid())) and$a$,
                  $a$select public.is_staff() or (public.user_enabled((select auth.uid())) and public.aal_suficiente() and$a$);
  if d not like '%aal_suficiente%' then raise exception 'can_read_account: texto não encontrado'; end if;
  execute d;

  d := pg_get_functiondef('public.pode_aceder_empresa(uuid)'::regprocedure);
  d := replace(d, $a$    public.user_enabled((select auth.uid()))$a$,
                  $a$    public.user_enabled((select auth.uid())) and public.aal_suficiente()$a$);
  if d not like '%aal_suficiente%' then raise exception 'pode_aceder_empresa: texto não encontrado'; end if;
  execute d;
end $x$;

-- Uma política restritiva em cada tabela com RLS e no Storage. As
-- permissivas continuam a decidir o quê; esta decide se a sessão chega.
do $x$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' and rowsecurity loop
    execute format('create policy dois_fatores on public.%I as restrictive for all to authenticated '
                   'using ((select public.aal_suficiente())) with check ((select public.aal_suficiente()))', t.tablename);
  end loop;
end $x$;
create policy dois_fatores on storage.objects as restrictive for all to authenticated
  using ((select public.aal_suficiente())) with check ((select public.aal_suficiente()));

-- A pergunta depois da entrada.
alter table public.profiles add column mfa_nao_perguntar boolean not null default false;

create function public.nao_perguntar_mfa(p_valor boolean) returns void
language sql security definer set search_path = '' as $$
  update public.profiles set mfa_nao_perguntar = coalesce(p_valor, false) where id = auth.uid()
$$;

-- O contexto de cada portal: falta o segundo fator?
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.get_portal_context()'::regprocedure);
  d := replace(d, $a$return jsonb_build_object('id',target,$a$, $a$return jsonb_build_object('id',target,'aal_em_falta',not public.aal_suficiente(),$a$);
  if d not like '%aal_em_falta%' then raise exception 'get_portal_context: texto não encontrado'; end if;
  execute d;

  d := pg_get_functiondef('public.portal_empresas()'::regprocedure);
  d := replace(d, $a$  return jsonb_build_object(
    'id', eu,$a$, $a$  return jsonb_build_object(
    'id', eu,
    'aal_em_falta', not public.aal_suficiente(),
    'mfa_nao_perguntar', coalesce(perfil.mfa_nao_perguntar, false),$a$);
  if d not like '%aal_em_falta%' then raise exception 'portal_empresas: texto não encontrado'; end if;
  execute d;
end $x$;

-- Os códigos por email.
create table public.codigos_verificacao (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  finalidade text not null check (finalidade in ('desativar_2fa')),
  resumo text not null check (resumo ~ '^[0-9a-f]{64}$'),
  expira_em timestamptz not null,
  tentativas integer not null default 0,
  usado_em timestamptz,
  criado_em timestamptz not null default now()
);
create index codigos_verificacao_pessoa on public.codigos_verificacao(user_id, finalidade, criado_em desc);
alter table public.codigos_verificacao enable row level security;
revoke all on public.codigos_verificacao from anon, authenticated;
grant select, insert, update, delete on public.codigos_verificacao to service_role;

-- Quem tem o segundo fator ativo (para a gestão).
create function public.com_dois_fatores(ids uuid[]) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  return coalesce((select array_agg(distinct f.user_id) from auth.mfa_factors f
                    where f.user_id = any(ids) and f.status = 'verified'), '{}');
end $$;

revoke all on function public.nao_perguntar_mfa(boolean) from public, anon;
grant execute on function public.nao_perguntar_mfa(boolean) to authenticated;
revoke all on function public.com_dois_fatores(uuid[]) from public, anon;
grant execute on function public.com_dois_fatores(uuid[]) to authenticated;

commit;
