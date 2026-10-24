-- Avisos de desempenho da auditoria do Supabase.
--
-- Nada disto se nota hoje, com um punhado de registos. Nota-se quando a
-- campanha encher: sem índice, cada verificação de chave estrangeira e cada
-- apagamento na tabela referenciada passa a varrer a tabela inteira.

begin;

-- 1. Políticas que reavaliavam auth.uid() linha a linha -----------------------
--
-- O resto da base já envolve estas chamadas num subselect, o que faz o
-- Postgres calculá-las uma vez por consulta em vez de uma vez por linha.
-- Estas três escaparam. As condições são as mesmas; muda só quando são
-- avaliadas.
--
-- can_read_account(account_id) fica onde está: depende da linha, não pode ser
-- içado para fora sem mudar o que a política decide.

alter policy companies_read on public.companies using (
  (select public.is_staff())
  or (
    (select public.user_enabled(auth.uid()))
    and exists (
      select 1 from public.company_users cu
      where cu.company_id = companies.id
        and cu.user_id = (select auth.uid())
        and cu.active
    )
  )
);

alter policy company_users_read on public.company_users using (
  (select public.is_staff())
  or (user_id = (select auth.uid()) and (select public.user_enabled(auth.uid())))
);

alter policy household_invitations_read on public.household_invitations using (
  public.can_read_account(account_id) or accepted_by = (select auth.uid())
);

-- 2. Chave estrangeira duplicada ---------------------------------------------
--
-- payments tinha duas chaves estrangeiras idênticas sobre invoice_id. Cada
-- inserção era verificada duas vezes, pela mesma regra.

alter table public.payments drop constraint if exists payments_invoice_id_fkey1;

-- 3. Índices de cobertura das chaves estrangeiras ----------------------------
--
-- Só as que não tinham já um índice com as suas colunas à cabeça. Onde o
-- índice existente servia — documents_case_id_idx, irs_checkouts_case_created,
-- messages_case_id_created_at_idx — não se acrescenta nada.

create index if not exists case_people_account_case on public.case_people (account_id, case_id);
create index if not exists case_people_account_person on public.case_people (account_id, person_id);

create index if not exists company_users_user on public.company_users (user_id);
create index if not exists discount_codes_allowed_user on public.discount_codes (allowed_user);

create index if not exists documents_account_case_income on public.documents (account_id, case_id, income_id);
create index if not exists documents_uploaded_by on public.documents (uploaded_by);

create index if not exists household_invitations_accepted_by on public.household_invitations (accepted_by);

create index if not exists income_records_account_case_property on public.income_records (account_id, case_id, property_id);
create index if not exists income_records_case_person on public.income_records (case_id, person_id);

create index if not exists invitation_requests_requested_by on public.invitation_requests (requested_by);

create index if not exists irs_checkouts_account_case on public.irs_checkouts (account_id, case_id);
create index if not exists irs_checkouts_user on public.irs_checkouts (user_id);

create index if not exists messages_account_case on public.messages (account_id, case_id);
create index if not exists messages_author on public.messages (author_id);

create index if not exists payments_account_invoice on public.payments (account_id, invoice_id);
create index if not exists payments_invoice on public.payments (invoice_id);

create index if not exists profiles_forced_discount on public.profiles (forced_discount_id);

create index if not exists progress_events_account_case on public.progress_events (account_id, case_id);
create index if not exists progress_events_author on public.progress_events (author_id);

create index if not exists staff_users_managed_by on public.staff_users (managed_by);

commit;
