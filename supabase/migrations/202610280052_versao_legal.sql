-- Termos e Política de Privacidade revistos (2026-10-28.1): pagamento pela
-- Stripe, senhas das Finanças cifradas, pagar depois de submeter, livre
-- resolução e registo de atividade com IP.
--
-- A versão estava escrita à mão em sete funções. Passa a viver numa só, e
-- mudar de versão volta a ser uma linha. Quem aceitou a versão anterior é
-- levado a aceitar esta na entrada seguinte (o portal já tem esse ecrã).
begin;

create or replace function public.versao_legal()
returns text language sql immutable set search_path = '' as $$ select '2026-10-28.1' $$;
grant execute on function public.versao_legal() to anon, authenticated;

do $x$
declare f record; d text;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proname <> 'versao_legal'
       and pg_get_functiondef(p.oid) like '%''2026-10-23.3''%'
  loop
    d := replace(pg_get_functiondef(f.oid), '''2026-10-23.3''', 'public.versao_legal()');
    execute d;
  end loop;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prokind = 'f'
               and pg_get_functiondef(p.oid) like '%2026-10-23.3%') then
    raise exception 'versão legal: ficou uma função com a versão antiga';
  end if;
end $x$;

commit;
