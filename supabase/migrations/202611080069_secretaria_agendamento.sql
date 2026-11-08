-- O relógio da Secretária: de hora a hora, a base chama a Gestão para fechar o
-- que acabou e enviar o que está na hora. (O Vercel Hobby só corre tarefas uma
-- vez por dia; a cadência precisa de hora certa.) A chave nasce aqui, só o
-- hash fica numa tabela, e nunca passa por ficheiros ou variáveis.
begin;

do $x$
declare
  chave text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  url text := 'https://gestao.rr-contabilidade.com/api/secretaria/tarefas';
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    return;
  end if;
  create extension if not exists pg_net with schema extensions;
  create extension if not exists pg_cron with schema pg_catalog;
  insert into public.secretaria_chave (hash) values (encode(sha256(convert_to(chave, 'UTF8')), 'hex'))
    on conflict (id) do update set hash = excluded.hash;
  perform cron.schedule('secretaria-tarefas', '2 * * * *',
    format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb, timeout_milliseconds := 55000)',
           url, json_build_object('Content-Type', 'application/json', 'x-secretaria-chave', chave)::text, '{}'));
end $x$;

commit;
