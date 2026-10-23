begin;
-- Immutable acceptance history. Versions match the IRS application's lib/legal.ts.
create table public.legal_acceptances (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 terms_version text not null,
 privacy_version text not null,
 accepted_at timestamptz not null default now(),
 source text not null check(source in ('registration','authenticated_confirmation')),
 unique(user_id,terms_version,privacy_version)
);
alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from anon,authenticated;
grant select on public.legal_acceptances to authenticated;
create policy acceptance_read on public.legal_acceptances for select to authenticated
 using(user_id=(select auth.uid()) or public.is_staff());

create function public.capture_registration_acceptance() returns trigger
 language plpgsql security definer set search_path='' as $$
begin
 if new.raw_user_meta_data->>'terms_accepted'='true'
 and new.raw_user_meta_data->>'terms_version'='2026-10-23.1'
 and new.raw_user_meta_data->>'privacy_version'='2026-10-23.1' then
  insert into public.legal_acceptances(user_id,terms_version,privacy_version,source)
  values(new.id,'2026-10-23.1','2026-10-23.1','registration') on conflict do nothing;
 end if;
 return new;
end $$;
create trigger on_auth_legal_acceptance after insert on auth.users
 for each row execute function public.capture_registration_acceptance();
revoke all on function public.capture_registration_acceptance() from public;

create function public.record_legal_acceptance() returns void
 language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501';end if;
 insert into public.legal_acceptances(user_id,terms_version,privacy_version,source)
 values(auth.uid(),'2026-10-23.1','2026-10-23.1','authenticated_confirmation') on conflict do nothing;
end $$;
revoke all on function public.record_legal_acceptance() from public;
grant execute on function public.record_legal_acceptance() to authenticated;

-- Consent cannot be bypassed through a direct PostgREST call to fiscal data.
create or replace function public.can_read_account(account uuid) returns boolean
 language sql stable security definer set search_path='' as $$
 select public.is_staff() or (
  exists(select 1 from public.legal_acceptances la
    where la.user_id=(select auth.uid()) and la.terms_version='2026-10-23.1' and la.privacy_version='2026-10-23.1')
  and exists(select 1 from public.account_access aa join public.client_accounts ca on ca.id=aa.account_id
    where aa.account_id=account and aa.user_id=(select auth.uid()) and aa.active and aa.role='owner' and aa.irs and ca.status='active')
 )
$$;
-- Existing users are not marked as having accepted on their behalf.
commit;
