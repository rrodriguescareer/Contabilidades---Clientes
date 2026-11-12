-- A chave estrangeira dos modelos por cliente não tinha índice (o índice único
-- usa uma expressão e não a cobre): apagar uma empresa percorria a tabela toda.
begin;

create index if not exists secretaria_modelos_empresa on public.secretaria_modelos(company_id);

commit;
