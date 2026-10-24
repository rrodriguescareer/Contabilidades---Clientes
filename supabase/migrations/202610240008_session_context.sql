begin;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_users s join auth.users u on u.id=s.user_id join public.profiles p on p.id=s.user_id
 where s.user_id=(select auth.uid()) and s.active and u.email_confirmed_at is not null
 and lower(u.email)='contabilidade.rubenrodrigues@gmail.com' and p.disabled_at is null and p.deleted_at is null
 and coalesce((to_jsonb(u)->>'banned_until')::timestamptz,'-infinity'::timestamptz)<=now())
$$;
-- One authenticated lookup replaces repeated profile, role and consent requests.
create function public.get_portal_context() returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid:=auth.uid(); auth_user auth.users; profile public.profiles;
begin
 if target is null then raise exception 'Authentication required' using errcode='42501';end if;
 select * into auth_user from auth.users where id=target;
 if not found then raise exception 'Authentication required' using errcode='42501';end if;
 if coalesce((to_jsonb(auth_user)->>'banned_until')::timestamptz,'-infinity'::timestamptz)>now() then raise exception 'Account blocked' using errcode='42501';end if;
 -- Recover a missing profile without overwriting existing data or granting IRS access.
 insert into public.profiles(id,email,full_name)
 values(target,coalesce(auth_user.email,''),coalesce(nullif(left(auth_user.raw_user_meta_data->>'full_name',200),''),'Novo utilizador'))
 on conflict(id) do nothing;
 select * into strict profile from public.profiles where id=target;
 -- Only the verified Auth identity can provision the explicitly designated owner.
 -- A deliberately disabled staff row is never reactivated by signing in.
 if lower(auth_user.email)='contabilidade.rubenrodrigues@gmail.com'
 and auth_user.email_confirmed_at is not null and profile.disabled_at is null and profile.deleted_at is null then
  insert into public.staff_users(user_id) values(target) on conflict(user_id) do nothing;
 end if;
 return jsonb_build_object('id',target,'email',auth_user.email,
  'email_confirmed',auth_user.email_confirmed_at is not null,
  'is_staff',public.is_staff(),'profile',to_jsonb(profile),
  'legal_accepted',exists(select 1 from public.legal_acceptances where user_id=target and terms_version='2026-10-23.3' and privacy_version='2026-10-23.3'));
end $$;
revoke all on function public.get_portal_context() from public,anon;
grant execute on function public.get_portal_context() to authenticated;

create index if not exists invoices_account_issued on public.invoices(account_id,issued_at desc);
create index if not exists payments_account_lookup on public.payments(account_id);
create index if not exists household_invitations_account_created on public.household_invitations(account_id,created_at desc);
create index if not exists irs_checkouts_case_created on public.irs_checkouts(case_id,created_at desc);
create index if not exists task_alerts_pending_created on public.task_alerts(created_at desc) where resolved_at is null;

-- Supabase Realtime still applies SELECT RLS to every subscriber.
do $realtime$
declare tab text;
begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  foreach tab in array array['messages','progress_events','documents','irs_checkouts'] loop
   if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=tab) then
    execute format('alter publication supabase_realtime add table public.%I',tab);
   end if;
  end loop;
 end if;
end $realtime$;
commit;
