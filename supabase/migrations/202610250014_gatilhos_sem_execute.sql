-- Três funções de gatilho tinham EXECUTE aberto a anon e authenticated.
--
-- Não são chamáveis de forma útil — fora de um gatilho não há NEW nem OLD e a
-- chamada rebenta — mas apareciam expostas em /rest/v1/rpc/ sem razão. A
-- guard_case_collection, do mesmo tipo, já estava fechada: isto alinha as
-- outras pelo mesmo critério.
--
-- Revogar EXECUTE não impede os gatilhos de correr: um gatilho executa com os
-- privilégios do dono da tabela, não com os de quem fez a escrita.

begin;

revoke all on function public.sync_profile() from public, anon, authenticated;
revoke all on function public.capture_registration_acceptance() from public, anon, authenticated;
revoke all on function public.alert_tax_2fa() from public, anon, authenticated;

commit;
