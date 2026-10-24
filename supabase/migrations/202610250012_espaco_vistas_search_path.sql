-- As funções de vista tinham ficado sem search_path fixo, ao contrário de
-- todas as outras da base. Qualificam tudo com public. e auth., por isso o
-- resultado não muda — mas deixa de depender do search_path de quem chama,
-- que é o que o linter do Supabase assinala.
--
-- São `security invoker`, logo correm com os privilégios de quem chama e a
-- autorização continua a ser feita pelas políticas de RLS.

begin;

alter function public.espaco_irs(text, uuid) set search_path = '';
alter function public.espaco_gabinete(text, uuid) set search_path = '';

commit;
