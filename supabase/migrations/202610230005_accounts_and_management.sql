begin;
alter table public.profiles add column street text, add column postal_code text, add column locality text,
 add column onboarding_completed_at timestamptz, add column disabled_at timestamptz, add column deleted_at timestamptz;

-- The professional identity is verified by Auth, never by editable user metadata.
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_users s join auth.users u on u.id=s.user_id
 where s.user_id=(select auth.uid()) and s.active and u.email_confirmed_at is not null
 and lower(u.email)='contabilidade.rubenrodrigues@gmail.com')
$$;
insert into public.staff_users(user_id)
 select id from auth.users where lower(email)='contabilidade.rubenrodrigues@gmail.com' and email_confirmed_at is not null
 on conflict(user_id) do update set active=true;
create function public.recognize_professional() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if lower(new.email)='contabilidade.rubenrodrigues@gmail.com' and new.email_confirmed_at is not null then
  insert into public.staff_users(user_id) values(new.id) on conflict(user_id) do update set active=true;
 end if;
 if tg_op='UPDATE' and new.email is distinct from old.email then
  update public.profiles set email=coalesce(new.email,'') where id=new.id;
  update public.people p set email=new.email from public.profiles pr join public.account_access a on a.user_id=pr.id and a.role='owner' where pr.id=new.id and p.account_id=a.account_id and p.nif=pr.nif;
 end if;
 return new;
end $$;
create trigger recognize_professional after insert or update of email,email_confirmed_at on auth.users
 for each row execute function public.recognize_professional();
revoke all on function public.recognize_professional() from public,anon,authenticated;

create function public.user_enabled(target uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p join auth.users u on u.id=p.id
 where p.id=target and p.disabled_at is null and p.deleted_at is null and u.email_confirmed_at is not null)
$$;
revoke all on function public.user_enabled(uuid) from public,anon;
grant execute on function public.user_enabled(uuid) to authenticated;
create or replace function public.can_read_account(account uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.is_staff() or (public.user_enabled((select auth.uid())) and
 exists(select 1 from public.legal_acceptances l where l.user_id=(select auth.uid()) and l.terms_version='2026-10-23.3' and l.privacy_version='2026-10-23.3') and
 exists(select 1 from public.account_access a join public.client_accounts c on c.id=a.account_id
 where a.account_id=account and a.user_id=(select auth.uid()) and a.active and a.irs and a.role='owner' and c.status='active'))
$$;
create or replace function public.capture_registration_acceptance() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.raw_user_meta_data->>'terms_accepted'='true' and new.raw_user_meta_data->>'terms_version'='2026-10-23.3' and new.raw_user_meta_data->>'privacy_version'='2026-10-23.3' then
  insert into public.legal_acceptances(user_id,terms_version,privacy_version,source)
  values(new.id,'2026-10-23.3','2026-10-23.3','registration') on conflict do nothing;
 end if;return new;
end $$;
create or replace function public.record_legal_acceptance(expected_terms text,expected_privacy text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.user_enabled(auth.uid()) then raise exception 'Authentication required' using errcode='42501';end if;
 if expected_terms is distinct from '2026-10-23.3' or expected_privacy is distinct from '2026-10-23.3' then raise exception 'Legal version mismatch' using errcode='22023';end if;
 insert into public.legal_acceptances(user_id,terms_version,privacy_version,source) values(auth.uid(),'2026-10-23.3','2026-10-23.3','authenticated_confirmation') on conflict do nothing;
end $$;

create function public.save_personal_profile(person_name text,birth date,tax_id text,telephone text,address_street text,address_postal text,address_locality text,two_factor boolean)
 returns uuid language plpgsql security definer set search_path='' as $$
declare target uuid:=auth.uid(); profile public.profiles; account uuid; owner_count integer; holder uuid; active_access boolean;
begin
 if not public.user_enabled(target) then raise exception 'Authentication required' using errcode='42501';end if;
 if not public.is_staff() and not exists(select 1 from public.legal_acceptances l where l.user_id=target and l.terms_version='2026-10-23.3' and l.privacy_version='2026-10-23.3') then raise exception 'Acceptance required' using errcode='42501';end if;
 if person_name is null or length(btrim(person_name)) not between 1 and 200 or birth is null or birth>current_date
 or tax_id is null or tax_id !~ '^[1-9][0-9]{8}$' or telephone is null or length(telephone) not between 7 and 30
 or address_street is null or length(btrim(address_street)) not between 1 and 300
 or address_postal is null or address_postal !~ '^[0-9]{4}-[0-9]{3}$'
 or address_locality is null or length(btrim(address_locality)) not between 1 and 100 then raise exception 'Invalid personal data' using errcode='22023';end if;
 select * into strict profile from public.profiles where id=target for update;
 select count(*) into owner_count from public.account_access a where a.user_id=target and a.role='owner';
 if owner_count>1 then raise exception 'Multiple owner accounts require professional assistance' using errcode='22023';end if;
 if owner_count=1 then
  select a.account_id,(a.active and a.irs and c.status='active') into account,active_access from public.account_access a join public.client_accounts c on c.id=a.account_id where a.user_id=target and a.role='owner';
  if not active_access then raise exception 'IRS access disabled' using errcode='42501';end if;
  select p.id into holder from public.people p where p.account_id=account and p.nif=profile.nif;
  if holder is null then raise exception 'Account holder requires professional assistance' using errcode='22023';end if;
 else
  insert into public.client_accounts(name) values(btrim(person_name)) returning id into account;
  insert into public.account_access(account_id,user_id,role,irs) values(account,target,'owner',true);
 end if;
 update public.profiles set full_name=btrim(person_name),birth_date=birth,nif=tax_id,phone=telephone,street=btrim(address_street),postal_code=address_postal,locality=btrim(address_locality),
 address=btrim(address_street)||', '||address_postal||' '||btrim(address_locality),onboarding_completed_at=coalesce(onboarding_completed_at,now()) where id=target;
 if holder is null then
  insert into public.people(account_id,full_name,birth_date,nif,email,tax_two_factor)
  values(account,btrim(person_name),birth,tax_id,profile.email,two_factor) returning id into holder;
 else
  update public.people set full_name=btrim(person_name),birth_date=birth,nif=tax_id,email=profile.email,tax_two_factor=two_factor where id=holder;
 end if;
 if not exists(select 1 from public.irs_cases c where c.account_id=account) then
  insert into public.irs_cases(account_id,tax_year) values(account,extract(year from current_date)::int-1);
  insert into public.case_people(account_id,case_id,person_id,relationship)
  select account,c.id,holder,'titular' from public.irs_cases c where c.account_id=account;
 end if;
 return account;
end $$;
revoke all on function public.save_personal_profile(text,date,text,text,text,text,text,boolean) from public,anon;
grant execute on function public.save_personal_profile(text,date,text,text,text,text,text,boolean) to authenticated;

create table public.management_audit (
 id uuid primary key default gen_random_uuid(),actor_id uuid not null, target_id uuid,
 action text not null,created_at timestamptz not null default now()
);
alter table public.management_audit enable row level security;
revoke all on public.management_audit from anon,authenticated;
grant select on public.management_audit to authenticated;
grant insert on public.management_audit to service_role;
create policy audit_read on public.management_audit for select to authenticated using(public.is_staff());
create function public.set_user_blocked(target uuid,blocked boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_staff() or target=auth.uid() then raise exception 'Not authorized' using errcode='42501';end if;
 update public.profiles set disabled_at=case when blocked then now() else null end where id=target and deleted_at is null;
 if not found then raise exception 'User unavailable';end if;
 if blocked then update public.account_access set active=false where user_id=target;end if;
 insert into public.management_audit(actor_id,target_id,action) values(auth.uid(),target,case when blocked then 'user_blocked' else 'user_unblocked' end);
end $$;
create function public.prepare_user_deletion(target uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_staff() or target=auth.uid() then raise exception 'Not authorized' using errcode='42501';end if;
 perform public.set_user_blocked(target,true);
 insert into public.management_audit(actor_id,target_id,action) values(auth.uid(),target,'user_deletion_requested');
end $$;
create function public.finish_user_deletion(target uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_staff() or target=auth.uid() then raise exception 'Not authorized' using errcode='42501';end if;
 update public.profiles set deleted_at=now(),disabled_at=now(),email='',full_name='Utilizador eliminado',birth_date=null,nif=null,phone=null,address=null,street=null,postal_code=null,locality=null where id=target;
 insert into public.management_audit(actor_id,target_id,action) values(auth.uid(),target,'user_authentication_deleted');
end $$;
revoke all on function public.set_user_blocked(uuid,boolean),public.prepare_user_deletion(uuid),public.finish_user_deletion(uuid) from public,anon;
grant execute on function public.set_user_blocked(uuid,boolean),public.prepare_user_deletion(uuid),public.finish_user_deletion(uuid) to authenticated;

create table public.companies (
 id uuid primary key default gen_random_uuid(),name text not null check(length(btrim(name)) between 1 and 200),
 nif text not null unique check(nif ~ '^[1-9][0-9]{8}$'),active boolean not null default true,created_at timestamptz not null default now()
);
create table public.company_users (
 company_id uuid not null references public.companies(id),user_id uuid not null references public.profiles(id),
 active boolean not null default true,created_at timestamptz not null default now(),primary key(company_id,user_id)
);
alter table public.companies enable row level security;alter table public.company_users enable row level security;
revoke all on public.companies,public.company_users from anon,authenticated;
grant select,insert,update on public.companies,public.company_users to authenticated;
create policy companies_read on public.companies for select to authenticated using(public.is_staff() or (public.user_enabled(auth.uid()) and exists(select 1 from public.company_users cu where cu.company_id=id and cu.user_id=auth.uid() and cu.active)));
create policy company_users_read on public.company_users for select to authenticated using(public.is_staff() or (user_id=auth.uid() and public.user_enabled(auth.uid())));
create policy companies_manage on public.companies for all to authenticated using(public.is_staff()) with check(public.is_staff());
create policy company_users_manage on public.company_users for all to authenticated using(public.is_staff()) with check(public.is_staff());
create function public.create_company(company_name text,tax_id text,client_user uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare company uuid;
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501';end if;
 if not exists(select 1 from public.profiles where id=client_user and deleted_at is null) then raise exception 'Client unavailable';end if;
 insert into public.companies(name,nif) values(btrim(company_name),tax_id) returning id into company;
 insert into public.company_users(company_id,user_id) values(company,client_user);
 return company;
end $$;
revoke all on function public.create_company(text,text,uuid) from public,anon;
grant execute on function public.create_company(text,text,uuid) to authenticated;

create table public.household_invitations (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,person_id uuid not null,
 email text not null check(length(email) between 3 and 254),token_hash text not null unique,
 state text not null default 'created' check(state in ('created','sent','accepted','revoked','failed')),
 created_by uuid not null default auth.uid(),accepted_by uuid references public.profiles(id),
 expires_at timestamptz not null default now()+interval '7 days',accepted_at timestamptz,created_at timestamptz not null default now(),
 foreign key(account_id,person_id) references public.people(account_id,id)
);
create unique index one_pending_household_invitation on public.household_invitations(account_id,person_id) where state in ('created','sent');
alter table public.household_invitations enable row level security;
revoke all on public.household_invitations from anon,authenticated;
grant select(id,account_id,person_id,email,state,expires_at,accepted_at,accepted_by,created_at) on public.household_invitations to authenticated;
create policy household_invitations_read on public.household_invitations for select to authenticated using(public.can_read_account(account_id) or accepted_by=auth.uid());
create function public.create_household_invitation(account uuid,person uuid,invited_email text,hash text) returns uuid language plpgsql security definer set search_path='' as $$
declare invitation uuid;
begin
 if not public.can_read_account(account) then raise exception 'Not authorized' using errcode='42501';end if;
 if hash is null or hash !~ '^[a-f0-9]{64}$' or invited_email is null or invited_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid invitation';end if;
 perform 1 from public.people where id=person and account_id=account for update;
 if not found then raise exception 'Person not found';end if;
 update public.household_invitations set state='revoked' where account_id=account and person_id=person and state in ('created','sent');
 insert into public.household_invitations(account_id,person_id,email,token_hash) values(account,person,lower(btrim(invited_email)),hash) returning id into invitation;
 return invitation;
end $$;
create function public.mark_household_invitation(invitation uuid,new_state text) returns void language plpgsql security definer set search_path='' as $$
begin
 if new_state not in ('sent','failed','revoked') then raise exception 'Invalid state';end if;
 update public.household_invitations set state=new_state where id=invitation and public.can_read_account(account_id) and state in ('created','sent');
end $$;
create function public.accept_household_invitation(token text) returns void language plpgsql security definer set search_path='' as $$
declare invitation public.household_invitations; current_email text;
begin
 if not public.user_enabled(auth.uid()) then raise exception 'Authentication required' using errcode='42501';end if;
 if not exists(select 1 from public.legal_acceptances where user_id=auth.uid() and terms_version='2026-10-23.3' and privacy_version='2026-10-23.3') then raise exception 'Acceptance required';end if;
 if token is null or token !~ '^[a-f0-9]{64}$' then raise exception 'Invitation unavailable';end if;
 select * into invitation from public.household_invitations where token_hash=encode(sha256(convert_to(token,'UTF8')),'hex') for update;
 if not found then raise exception 'Invitation unavailable';end if;
 if invitation.state='accepted' and invitation.accepted_by=auth.uid() then return;end if;
 select lower(email) into current_email from auth.users where id=auth.uid();
 if invitation.state not in ('created','sent') or invitation.expires_at<now() or invitation.email<>current_email
 or not exists(select 1 from public.client_accounts c join public.account_access a on a.account_id=c.id join public.profiles p on p.id=a.user_id where c.id=invitation.account_id and c.status='active' and a.role='owner' and a.irs and a.active and p.disabled_at is null and p.deleted_at is null) then raise exception 'Invitation unavailable';end if;
 update public.household_invitations set state='accepted',accepted_by=auth.uid(),accepted_at=now() where id=invitation.id;
 -- Acceptance links identities. It grants no access to other relatives or fiscal records.
end $$;
revoke all on function public.create_household_invitation(uuid,uuid,text,text),public.mark_household_invitation(uuid,text),public.accept_household_invitation(text) from public,anon;
grant execute on function public.create_household_invitation(uuid,uuid,text,text),public.mark_household_invitation(uuid,text),public.accept_household_invitation(text) to authenticated;
commit;
