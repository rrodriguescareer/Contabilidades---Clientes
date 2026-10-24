-- Separate administration, professional access and the IRS 2026 campaign.
begin;
alter table public.staff_users add column managed_by uuid references public.profiles(id);
alter table public.irs_cases add column campaign integer not null default 2026;
create index irs_campaign_recent on public.irs_cases(campaign,created_at desc);
create index access_user_account on public.account_access(user_id,account_id) where active and irs and role='owner';

create or replace function public.is_staff() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_users s join auth.users u on u.id=s.user_id join public.profiles p on p.id=s.user_id
 where s.user_id=(select auth.uid()) and s.active and u.email_confirmed_at is not null
 and p.disabled_at is null and p.deleted_at is null
 and coalesce((to_jsonb(u)->>'banned_until')::timestamptz,'-infinity'::timestamptz)<=now()
 and (lower(u.email)='contabilidade.rubenrodrigues@gmail.com' or exists(
 select 1 from auth.users owner_user where owner_user.id=s.managed_by and lower(owner_user.email)='contabilidade.rubenrodrigues@gmail.com' and owner_user.email_confirmed_at is not null)))
$$;
create function public.is_platform_owner() returns boolean language sql stable security definer set search_path='' as $$
 select public.is_staff() and exists(select 1 from auth.users where id=(select auth.uid()) and lower(email)='contabilidade.rubenrodrigues@gmail.com' and email_confirmed_at is not null)
$$;
revoke all on function public.is_platform_owner() from public,anon;
grant execute on function public.is_platform_owner() to authenticated;
create function public.set_staff_access(target uuid,enabled boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_platform_owner() or target=auth.uid() then raise exception 'Not authorized' using errcode='42501';end if;
 if not exists(select 1 from public.profiles where id=target and deleted_at is null and disabled_at is null) then raise exception 'User unavailable';end if;
 insert into public.staff_users(user_id,active,managed_by) values(target,enabled,auth.uid())
 on conflict(user_id) do update set active=excluded.active,managed_by=excluded.managed_by;
 insert into public.management_audit(actor_id,target_id,action) values(auth.uid(),target,case when enabled then 'accountant_access_granted' else 'accountant_access_revoked' end);
end $$;
revoke all on function public.set_staff_access(uuid,boolean) from public,anon;
grant execute on function public.set_staff_access(uuid,boolean) to authenticated;

-- Only the administrator manages users, companies and commercial conditions.
do $restrict_admin$
declare signature text; definition text;
begin
 foreach signature in array array['public.set_user_blocked(uuid,boolean)','public.prepare_user_deletion(uuid)','public.finish_user_deletion(uuid)','public.create_company(text,text,uuid)','public.set_client_billing(uuid,boolean,uuid)','public.approve_client(uuid,text,integer)'] loop
  select pg_get_functiondef(signature::regprocedure) into definition;
  execute replace(definition,'public.is_staff()','public.is_platform_owner()');
 end loop;
end $restrict_admin$;
alter policy access_manage on public.account_access using((select public.is_platform_owner())) with check((select public.is_platform_owner()));
alter policy account_manage on public.client_accounts using((select public.is_platform_owner())) with check((select public.is_platform_owner()));
alter policy companies_manage on public.companies using((select public.is_platform_owner())) with check((select public.is_platform_owner()));
alter policy company_users_manage on public.company_users using((select public.is_platform_owner())) with check((select public.is_platform_owner()));
alter policy discount_manage on public.discount_codes using((select public.is_platform_owner())) with check((select public.is_platform_owner()));
alter policy audit_read on public.management_audit using((select public.is_platform_owner()));
create policy owner_staff_read on public.staff_users for select to authenticated using((select public.is_platform_owner()));

create table public.payment_settings(
 id boolean primary key default true check(id),enabled boolean not null default false,
 api_version text not null default '' check(api_version='' or api_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),updated_at timestamptz not null default now()
);
insert into public.payment_settings(id) values(true);
create table public.integration_secrets(
 scope text primary key,encrypted_value text not null,updated_at timestamptz not null default now()
);
alter table public.payment_settings enable row level security;
alter table public.integration_secrets enable row level security;
revoke all on public.payment_settings,public.integration_secrets from public,anon,authenticated;
grant select on public.payment_settings to authenticated;
create policy settings_owner_read on public.payment_settings for select to authenticated using((select public.is_platform_owner()));
grant all on public.payment_settings,public.integration_secrets to service_role;

create function public.management_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501';end if;
 return jsonb_build_object(
 'users',case when public.is_platform_owner() then (select count(*) from public.profiles where deleted_at is null) end,
 'companies',case when public.is_platform_owner() then (select count(*) from public.companies where active) end,
 'open_cases',(select count(*) from public.irs_cases where campaign=2026 and status<>'completed'),
 'pending_payments',case when public.is_platform_owner() then (select count(*) from public.irs_checkouts where state in ('creating','pending','unknown')) end);
end $$;
revoke all on function public.management_overview() from public,anon;
grant execute on function public.management_overview() to authenticated;

-- Identity and client navigation in one verified request. No client-supplied user ID.
create or replace function public.get_portal_context() returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=auth.uid(); auth_user auth.users; profile public.profiles; staff boolean; accounts jsonb; cases jsonb;
begin
 if target is null then raise exception 'Authentication required' using errcode='42501';end if;
 select * into auth_user from auth.users where id=target;
 if not found or coalesce((to_jsonb(auth_user)->>'banned_until')::timestamptz,'-infinity'::timestamptz)>now() then raise exception 'Account unavailable' using errcode='42501';end if;
 select * into profile from public.profiles where id=target;
 if not found then
  insert into public.profiles(id,email,full_name) values(target,coalesce(auth_user.email,''),'Novo utilizador') on conflict(id) do nothing;
  select * into strict profile from public.profiles where id=target;
 end if;
 if lower(auth_user.email)='contabilidade.rubenrodrigues@gmail.com' and auth_user.email_confirmed_at is not null and profile.disabled_at is null and profile.deleted_at is null then
  insert into public.staff_users(user_id) values(target) on conflict(user_id) do nothing;
 end if;
 staff:=public.is_staff();
 if not staff and public.user_enabled(target) then
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'status',c.status) order by c.created_at),'[]'::jsonb) into accounts
  from public.client_accounts c where public.can_read_account(c.id);
  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc),'[]'::jsonb) into cases
  from public.irs_cases c where c.campaign=2026 and public.can_read_account(c.account_id);
 end if;
 return jsonb_build_object('id',target,'email',auth_user.email,'email_confirmed',auth_user.email_confirmed_at is not null,'is_staff',staff,'profile',to_jsonb(profile),
 'legal_accepted',exists(select 1 from public.legal_acceptances where user_id=target and terms_version='2026-10-23.3' and privacy_version='2026-10-23.3'),
 'accounts',case when staff then null else coalesce(accounts,'[]'::jsonb) end,'cases',case when staff then null else coalesce(cases,'[]'::jsonb) end);
end $$;

-- Campaign stays fixed. Do not erase existing income, documents or payment records.
do $campaign$
declare definition text;
begin
 select pg_get_functiondef('public.save_personal_profile(text,date,text,text,text,text,text,boolean)'::regprocedure) into definition;
 execute replace(definition,'extract(year from current_date)::int-1','2025');
end $campaign$;

-- Materialize permitted accounts once per SELECT, instead of repeating authorization per row.
create function public.readable_accounts() returns setof uuid language plpgsql stable security definer set search_path='' as $$
begin
 if public.is_staff() then return query select id from public.client_accounts;return;end if;
 if not public.user_enabled(auth.uid()) or not exists(select 1 from public.legal_acceptances where user_id=auth.uid() and terms_version='2026-10-23.3' and privacy_version='2026-10-23.3') then return;end if;
 return query select c.id from public.client_accounts c join public.account_access a on a.account_id=c.id
 where a.user_id=auth.uid() and a.active and a.irs and a.role='owner' and c.status='active';
end $$;
revoke all on function public.readable_accounts() from public,anon;
grant execute on function public.readable_accounts() to authenticated;
alter policy account_read on public.client_accounts using(id in (select public.readable_accounts()));
alter policy person_read on public.people using(account_id in (select public.readable_accounts()));
alter policy case_read on public.irs_cases using(account_id in (select public.readable_accounts()));
alter policy case_person_read on public.case_people using(account_id in (select public.readable_accounts()));
alter policy resource_read on public.property_assets using(account_id in (select public.readable_accounts()));
alter policy resource_read on public.income_records using(account_id in (select public.readable_accounts()));
alter policy resource_read on public.documents using(account_id in (select public.readable_accounts()));
alter policy message_read on public.messages using(account_id in (select public.readable_accounts()));
alter policy progress_read on public.progress_events using(account_id in (select public.readable_accounts()));
alter policy invoice_read on public.invoices using(account_id in (select public.readable_accounts()));
alter policy payment_read on public.payments using(account_id in (select public.readable_accounts()));
alter policy invite_read on public.invitation_requests using(account_id in (select public.readable_accounts()));
alter policy checkout_read on public.irs_checkouts using(account_id in (select public.readable_accounts()));
alter policy profiles_read on public.profiles using(id=(select auth.uid()) or (select public.is_staff()));
alter policy access_read on public.account_access using(user_id=(select auth.uid()) or (select public.is_staff()));
alter policy alert_read on public.task_alerts using((select public.is_staff()));
commit;
