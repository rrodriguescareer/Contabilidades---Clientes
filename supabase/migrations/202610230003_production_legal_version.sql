begin;
-- Production legal texts: keep all previous acceptance records; require the new version.
create or replace function public.capture_registration_acceptance() returns trigger
 language plpgsql security definer set search_path='' as $$
begin
 if new.raw_user_meta_data->>'terms_accepted'='true'
 and new.raw_user_meta_data->>'terms_version'='2026-10-23.2'
 and new.raw_user_meta_data->>'privacy_version'='2026-10-23.2' then
  insert into public.legal_acceptances(user_id,terms_version,privacy_version,source)
  values(new.id,'2026-10-23.2','2026-10-23.2','registration') on conflict do nothing;
 end if;
 return new;
end $$;

drop function public.record_legal_acceptance();
create function public.record_legal_acceptance(expected_terms text,expected_privacy text) returns void
 language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501';end if;
 if expected_terms <> '2026-10-23.2' or expected_privacy <> '2026-10-23.2' or expected_terms is null or expected_privacy is null then raise exception 'Legal version mismatch' using errcode='22023';end if;
 insert into public.legal_acceptances(user_id,terms_version,privacy_version,source)
 values(auth.uid(),'2026-10-23.2','2026-10-23.2','authenticated_confirmation') on conflict do nothing;
end $$;

revoke all on function public.record_legal_acceptance(text,text) from public;
grant execute on function public.record_legal_acceptance(text,text) to authenticated;

create or replace function public.can_read_account(account uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select public.is_staff() or (
  exists(select 1 from public.legal_acceptances la
    where la.user_id=(select auth.uid()) and la.terms_version='2026-10-23.2' and la.privacy_version='2026-10-23.2')
  and exists(select 1 from public.account_access aa join public.client_accounts ca on ca.id=aa.account_id
    where aa.account_id=account and aa.user_id=(select auth.uid()) and aa.active and aa.role='owner' and aa.irs and ca.status='active')
 )
$$;
commit;
