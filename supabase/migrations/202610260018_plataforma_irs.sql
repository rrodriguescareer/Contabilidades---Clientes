-- Esquema do pós-login do IRS: residência fiscal, senhas das Finanças com
-- registo de consultas, rendimentos com titular e sub-tipo, mais-valias,
-- deduções, notas por separador e o percurso do processo.
begin;

/* ---------------------------------------------------- 1. perfil fiscal */
alter table public.profiles
  add column if not exists tax_residence text,
  add column if not exists tax_two_factor boolean not null default false,
  add column if not exists rep_name text,
  add column if not exists rep_nif text,
  add column if not exists rep_email text,
  add column if not exists rep_phone text;

alter table public.profiles drop constraint if exists profiles_tax_residence_check;
alter table public.profiles add constraint profiles_tax_residence_check
  check (tax_residence is null or tax_residence in ('continente','acores','madeira','ue','fora_ue'));

-- Fora da UE há sempre representante fiscal: sem ele a declaração não entra.
alter table public.profiles drop constraint if exists profiles_representante_check;
alter table public.profiles add constraint profiles_representante_check
  check (tax_residence is distinct from 'fora_ue'
         or (rep_name is not null and rep_nif is not null
             and (rep_email is not null or rep_phone is not null)));

alter table public.profiles drop constraint if exists profiles_rep_tamanhos_check;
alter table public.profiles add constraint profiles_rep_tamanhos_check
  check (coalesce(length(rep_name),0) <= 200 and coalesce(length(rep_nif),0) <= 30
         and coalesce(length(rep_email),0) <= 200 and coalesce(length(rep_phone),0) <= 40);

/* ------------------------------- 2. senhas das Finanças e as consultas */
-- A senha nunca fica em claro: chega aqui já cifrada pela aplicação, com a
-- mesma chave das restantes integrações. O cliente escreve-a e substitui-a,
-- mas não a lê de volta; quem a lê é o contabilista, e cada leitura fica
-- registada para o cliente poder ver.
create table if not exists public.tax_credentials (
  person_id uuid primary key references public.people(id) on delete cascade,
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  encrypted_password text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.tax_credential_views (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  viewed_by uuid not null references auth.users(id),
  viewed_at timestamptz not null default now()
);
create index if not exists tax_credential_views_pessoa_idx
  on public.tax_credential_views (person_id, viewed_at desc);

alter table public.tax_credentials enable row level security;
alter table public.tax_credential_views enable row level security;

create policy credencial_escreve on public.tax_credentials
  for insert with check (public.can_read_account(account_id));
create policy credencial_atualiza on public.tax_credentials
  for update using (public.can_read_account(account_id))
  with check (public.can_read_account(account_id));
create policy credencial_le on public.tax_credentials
  for select using (public.is_staff());

create policy consulta_le on public.tax_credential_views
  for select using (account_id in (select public.readable_accounts()));
create policy consulta_regista on public.tax_credential_views
  for insert with check (public.is_staff() and viewed_by = auth.uid());

/* ------------------------------------------------- 3. agregado familiar */
-- O titular é uma pessoa como as outras, distinguido pela relação.
alter table public.case_people drop constraint if exists case_people_relationship_check;
alter table public.case_people add constraint case_people_relationship_check
  check (relationship in ('titular','conjuge','descendente','ascendente','outro'));

/* ----------------------------------------------------- 4. rendimentos */
alter table public.income_records
  add column if not exists kind text,
  add column if not exists amount_cents bigint,
  add column if not exists young_irs boolean not null default false,
  add column if not exists studies_and_works boolean not null default false,
  add column if not exists foreign_scope text,
  add column if not exists acquired_on date,
  add column if not exists sold_on date,
  add column if not exists acquisition_cents bigint,
  add column if not exists sale_cents bigint,
  add column if not exists expenses_cents bigint,
  add column if not exists hpp_reinvestment boolean not null default false,
  add column if not exists hpp_credit_cents bigint,
  add column if not exists hpp_done boolean not null default false;

alter table public.income_records drop constraint if exists income_records_category_check;
alter table public.income_records add constraint income_records_category_check
  check (category in ('employment','pension','independent','property_sale',
                      'securities','property_rent','foreign_income','deduction'));

alter table public.income_records drop constraint if exists income_records_check;
-- Rendas e mais-valias de imóveis pendem de um imóvel; tudo o resto de um
-- titular do agregado. Estrangeiros também têm titular.
alter table public.income_records add constraint income_records_check
  check ((category in ('property_sale','property_rent')
            and property_id is not null and person_id is not null)
      or (category in ('employment','pension','independent','securities','foreign_income')
            and person_id is not null and property_id is null)
      or (category = 'deduction' and property_id is null));

alter table public.income_records drop constraint if exists income_records_kind_check;
alter table public.income_records add constraint income_records_kind_check
  check (kind is null or (length(kind) between 1 and 60));

alter table public.income_records drop constraint if exists income_records_foreign_scope_check;
alter table public.income_records add constraint income_records_foreign_scope_check
  check (foreign_scope is null or foreign_scope in
    ('employment','pension','independent','capital','rent','property_sale','securities','other'));

alter table public.income_records drop constraint if exists income_records_montantes_check;
alter table public.income_records add constraint income_records_montantes_check
  check (coalesce(amount_cents,0) >= 0 and coalesce(acquisition_cents,0) >= 0
     and coalesce(sale_cents,0) >= 0 and coalesce(expenses_cents,0) >= 0
     and coalesce(hpp_credit_cents,0) >= 0);

-- O reinvestimento só se pergunta quando há venda de imóvel.
alter table public.income_records drop constraint if exists income_records_hpp_check;
alter table public.income_records add constraint income_records_hpp_check
  check (category = 'property_sale' or (not hpp_reinvestment and not hpp_done and hpp_credit_cents is null));

alter table public.income_records drop constraint if exists income_records_datas_check;
alter table public.income_records add constraint income_records_datas_check
  check (acquired_on is null or sold_on is null or sold_on >= acquired_on);

/* -------------------------------------------------------- 5. imóveis */
alter table public.property_assets
  add column if not exists kind text not null default 'rent';
alter table public.property_assets drop constraint if exists property_assets_kind_check;
alter table public.property_assets add constraint property_assets_kind_check
  check (kind in ('rent','sale'));

/* ------------------------------------------------------ 6. documentos */
alter table public.documents
  add column if not exists property_id uuid references public.property_assets(id) on delete set null,
  add column if not exists category text,
  add column if not exists description text;

alter table public.documents drop constraint if exists documents_description_check;
alter table public.documents add constraint documents_description_check
  check (description is null or (length(description) between 3 and 200));

alter table public.documents drop constraint if exists documents_category_check;
alter table public.documents add constraint documents_category_check
  check (category is null or category in ('employment','pension','independent','property_sale',
    'securities','property_rent','foreign_income','deduction','other'));

-- Quando o contabilista descarrega um documento, o cliente fica a saber.
create table if not exists public.document_downloads (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents(id) on delete cascade,
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  downloaded_by uuid not null references auth.users(id),
  downloaded_at timestamptz not null default now()
);
create index if not exists document_downloads_doc_idx
  on public.document_downloads (document_id, downloaded_at desc);

alter table public.document_downloads enable row level security;
create policy descarga_le on public.document_downloads
  for select using (account_id in (select public.readable_accounts()));
create policy descarga_regista on public.document_downloads
  for insert with check (public.is_staff() and downloaded_by = auth.uid());

/* --------------------------------------- 7. notas por separador */
create table if not exists public.case_notes (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  case_id uuid not null references public.irs_cases(id) on delete cascade,
  tab text not null,
  body text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  unique (case_id, tab)
);
alter table public.case_notes drop constraint if exists case_notes_tab_check;
alter table public.case_notes add constraint case_notes_tab_check
  check (tab in ('employment','pension','independent','property_sale',
                 'securities','property_rent','foreign_income','deduction','household'));
alter table public.case_notes drop constraint if exists case_notes_body_check;
alter table public.case_notes add constraint case_notes_body_check
  check (length(body) <= 5000);

alter table public.case_notes enable row level security;
create policy nota_le on public.case_notes
  for select using (account_id in (select public.readable_accounts()));
create policy nota_cria on public.case_notes
  for insert with check (public.can_edit_case(account_id, case_id));
create policy nota_atualiza on public.case_notes
  for update using (public.can_edit_case(account_id, case_id))
  with check (public.can_edit_case(account_id, case_id));

/* ------------------------------------------ 8. deduções e benefícios */
create table if not exists public.case_deductions (
  case_id uuid primary key references public.irs_cases(id) on delete cascade,
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  use_efatura boolean not null default true,
  rented_home boolean not null default false,
  contract_reported boolean,
  rent_receipts boolean,
  landlord_invoices boolean,
  ppr boolean not null default false,
  ppr_person_id uuid references public.people(id) on delete set null,
  ascendant_expenses boolean not null default false,
  updated_at timestamptz not null default now()
);
-- As perguntas encadeadas só fazem sentido com a de cima ligada.
alter table public.case_deductions drop constraint if exists case_deductions_arrendamento_check;
alter table public.case_deductions add constraint case_deductions_arrendamento_check
  check (rented_home or (contract_reported is null and rent_receipts is null and landlord_invoices is null));
alter table public.case_deductions drop constraint if exists case_deductions_ppr_check;
alter table public.case_deductions add constraint case_deductions_ppr_check
  check (ppr or ppr_person_id is null);

alter table public.case_deductions enable row level security;
create policy deducao_le on public.case_deductions
  for select using (account_id in (select public.readable_accounts()));
create policy deducao_cria on public.case_deductions
  for insert with check (public.can_edit_case(account_id, case_id));
create policy deducao_atualiza on public.case_deductions
  for update using (public.can_edit_case(account_id, case_id))
  with check (public.can_edit_case(account_id, case_id));

/* ------------------------------------------- 9. percurso do processo */
-- Os estados antigos não descreviam o percurso que o cliente vê.
alter table public.irs_cases
  add column if not exists final_amount_cents bigint,
  add column if not exists final_direction text,
  add column if not exists status_changed_at timestamptz not null default now(),
  add column if not exists submitted_by_client_at timestamptz;

update public.irs_cases set status = case status
  when 'review' then 'validation'
  when 'missing' then 'validation'
  when 'authorization' then 'approved'
  when 'submitted' then 'filed'
  when 'completed' then 'closed'
  else status end;

alter table public.irs_cases drop constraint if exists irs_cases_status_check;
alter table public.irs_cases add constraint irs_cases_status_check
  check (status in ('collecting','submitted_by_client','accepted','validation',
                    'approved','submitting','filed','monitoring','closed'));

alter table public.irs_cases drop constraint if exists irs_cases_final_direction_check;
alter table public.irs_cases add constraint irs_cases_final_direction_check
  check (final_direction is null or final_direction in ('refund','payment'));

alter table public.irs_cases drop constraint if exists irs_cases_final_amount_check;
alter table public.irs_cases add constraint irs_cases_final_amount_check
  check (final_amount_cents is null or (final_amount_cents >= 0 and final_direction is not null));

/* -------------------------------------- 10. integração Cegid global */
-- As credenciais Cegid existiam só por empresa. A faturação do IRS é do
-- escritório, não de um cliente: precisa de um âmbito próprio.
comment on table public.integration_secrets is
  'Credenciais cifradas. Âmbitos: cegid:global (escritório), cegid:<empresa>, revolut:global.';

commit;
