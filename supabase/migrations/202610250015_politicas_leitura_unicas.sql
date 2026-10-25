-- Três tabelas tinham duas políticas permissivas de leitura, ambas avaliadas
-- em cada consulta. Passam a ter uma só, com a união exata das condições.
--
-- Onde a política de gestão era `for all`, ela cobria também o SELECT. Separá-la
-- por comando resolve a duplicação sem tirar nada a ninguém: a condição é a
-- mesma, só deixa de ser aplicada à leitura, que a política de leitura passa a
-- cobrir explicitamente.
--
-- A gestão escreve diretamente em company_users — associateCompany faz upsert e
-- toggleCompanyAccess faz update — por isso INSERT e UPDATE precisam mesmo de
-- política própria, com with_check no upsert.

begin;

-- staff_users: sem políticas de escrita; só se escreve por set_staff_access,
-- que é security definer e não passa por aqui.
drop policy owner_staff_read on public.staff_users;
drop policy staff_read on public.staff_users;
create policy staff_users_read on public.staff_users for select to authenticated
using ((select public.is_platform_owner()) or user_id = (select auth.uid()));

-- companies
drop policy companies_manage on public.companies;
create policy companies_insert on public.companies for insert to authenticated
with check ((select public.is_platform_owner()));
create policy companies_update on public.companies for update to authenticated
using ((select public.is_platform_owner()))
with check ((select public.is_platform_owner()));
create policy companies_delete on public.companies for delete to authenticated
using ((select public.is_platform_owner()));

alter policy companies_read on public.companies using (
  (select public.is_platform_owner())
  or (select public.is_staff())
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

-- company_users
drop policy company_users_manage on public.company_users;
create policy company_users_insert on public.company_users for insert to authenticated
with check ((select public.is_platform_owner()));
create policy company_users_update on public.company_users for update to authenticated
using ((select public.is_platform_owner()))
with check ((select public.is_platform_owner()));
create policy company_users_delete on public.company_users for delete to authenticated
using ((select public.is_platform_owner()));

alter policy company_users_read on public.company_users using (
  (select public.is_platform_owner())
  or (select public.is_staff())
  or (user_id = (select auth.uid()) and (select public.user_enabled(auth.uid())))
);

commit;
