-- Validação de segurança (novembro de 2026).
--
-- 1. O papel anónimo (quem não tem sessão) tinha as permissões por omissão
--    do Supabase em dez tabelas. O RLS já não o deixava ver nada (só os
--    avisos ativos, de propósito), mas a permissão não devia lá estar: sai de
--    todas, fica só a leitura dos avisos. E as tabelas novas deixam de a
--    receber por omissão.
-- 2. As tabelas que só o servidor usa (segredos, emails, registo de atividade,
--    códigos) deixam de ter permissões para sessões de clientes.
-- 3. Índices nas chaves estrangeiras que o Supabase assinalou.
begin;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
grant select on public.avisos to anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon, public;

revoke all on public.registo_atividade, public.emails, public.integration_secrets, public.codigos_verificacao from authenticated;

create index if not exists empresa_ficheiros_empresa on public.empresa_ficheiros(company_id);
create index if not exists empresa_prazos_empresa on public.empresa_prazos(company_id);
create index if not exists pricing_policies_origem on public.pricing_policies(origem);

commit;
