-- Revisão de desempenho para centenas de utilizadores em simultâneo.
-- 1. Índices nas chaves estrangeiras que não os tinham: sem eles, cada apagar
--    ou atualizar na tabela-mãe percorre a tabela-filha inteira.
-- 2. As duas políticas que chamavam auth.uid() por linha passam a chamá-lo uma
--    vez por consulta, como as restantes.
begin;

create index if not exists avisos_criado_por_idx on public.avisos(criado_por);
create index if not exists campaigns_criada_por_idx on public.campaigns(criada_por);
create index if not exists case_deductions_account_idx on public.case_deductions(account_id);
create index if not exists case_deductions_ppr_person_idx on public.case_deductions(ppr_person_id);
create index if not exists case_notes_account_idx on public.case_notes(account_id);
create index if not exists case_notes_updated_by_idx on public.case_notes(updated_by);
create index if not exists document_downloads_account_idx on public.document_downloads(account_id);
create index if not exists document_downloads_by_idx on public.document_downloads(downloaded_by);
create index if not exists documents_property_idx on public.documents(property_id);
create index if not exists pricing_policies_criada_por_idx on public.pricing_policies(criada_por);
create index if not exists tax_credential_views_account_idx on public.tax_credential_views(account_id);
create index if not exists tax_credential_views_by_idx on public.tax_credential_views(viewed_by);
create index if not exists tax_credentials_account_idx on public.tax_credentials(account_id);
create index if not exists tax_credentials_updated_by_idx on public.tax_credentials(updated_by);

alter policy descarga_regista on public.document_downloads
  with check (public.is_staff() and downloaded_by = (select auth.uid()));
alter policy consulta_regista on public.tax_credential_views
  with check (public.is_staff() and viewed_by = (select auth.uid()));

commit;
