-- INSTALACAO INICIAL: executar o ficheiro completo no SQL Editor do Supabase.
-- Gerado por npm run db:bundle. Inclui todas as migracoes, numa unica transacao.
-- Para uma instalacao existente, aplicar apenas as migracoes pendentes.
begin;
do $preflight$
declare existing_table text;
begin
 if to_regclass('auth.users') is null or to_regclass('storage.objects') is null then
  raise exception 'Abra o SQL Editor do projeto Supabase correto; faltam Auth ou Storage.';
 end if;
 select name into existing_table from unnest(array[
  'profiles','staff_users','client_accounts','account_access','people','irs_cases','case_people',
  'property_assets','income_records','documents','messages','progress_events','invoices','payments',
  'task_alerts','invitation_requests','legal_acceptances','management_audit','companies','company_users','household_invitations','discount_codes','irs_checkouts'
 ]) as tables(name) where to_regclass('public.'||name) is not null limit 1;
 if existing_table is not null then
  raise exception 'Ja existe public.%. A instalacao inicial foi interrompida sem alterar dados. Aplique apenas as migracoes pendentes.',existing_table;
 end if;
end $preflight$;

-- Source: 202610230001_core.sql
-- Apply once to the shared DEVELOPMENT Supabase project, from the management repository.
-- No service_role key is required by the applications.

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null,
 full_name text not null check (length(full_name) between 1 and 200),
 birth_date date, nif text check(nif ~ '^[0-9]{9}$'), phone text, address text,
 created_at timestamptz not null default now()
);
create table public.staff_users (
 user_id uuid primary key references auth.users(id) on delete cascade,
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create table public.client_accounts (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(name) between 1 and 200),
 status text not null default 'active' check(status in ('active','suspended','closed')),
 created_at timestamptz not null default now()
);
create table public.account_access (
 account_id uuid not null references public.client_accounts(id),
 user_id uuid not null references auth.users(id),
 role text not null default 'owner' check(role in ('owner','member')),
 irs boolean not null default false,
 business boolean not null default false,
 active boolean not null default true,
 primary key(account_id,user_id)
);
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_users where user_id=(select auth.uid()) and active)
$$;
create or replace function public.can_read_account(account uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.is_staff() or exists(
 select 1 from public.account_access aa join public.client_accounts ca on ca.id=aa.account_id
 where aa.account_id=account and aa.user_id=(select auth.uid()) and aa.active and aa.role='owner' and aa.irs and ca.status='active')
$$;

create table public.people (
 id uuid primary key default gen_random_uuid(),account_id uuid not null references public.client_accounts(id),
 full_name text not null check(length(full_name) between 1 and 200),birth_date date not null,
 nif text not null check(nif ~ '^[0-9]{9}$'),email text, tax_two_factor boolean not null default false,
 created_at timestamptz not null default now(),unique(account_id,id),unique(account_id,nif)
);
create table public.irs_cases (
 id uuid primary key default gen_random_uuid(),account_id uuid not null references public.client_accounts(id),
 tax_year integer not null check(tax_year between 2000 and 2100),
 label text not null default 'IRS',
 status text not null default 'collecting' check(status in ('collecting','review','missing','validation','authorization','submitted','completed')),
 created_at timestamptz not null default now(),unique(account_id,id)
);
create table public.case_people (
 account_id uuid not null,case_id uuid not null,person_id uuid not null,
 relationship text not null check(relationship in ('titular','conjuge','descendente','ascendente','outro')),
 primary key(case_id,person_id),foreign key(account_id,case_id) references public.irs_cases(account_id,id),foreign key(account_id,person_id) references public.people(account_id,id)
);
create unique index one_holder_per_case on public.case_people(case_id) where relationship='titular';
create table public.property_assets (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,
 label text not null check(length(label) between 1 and 100),description text,
 foreign key(account_id,case_id) references public.irs_cases(account_id,id),unique(account_id,case_id,id)
);
create table public.income_records (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,
 category text not null check(category in ('employment','pension','independent','property_sale','securities','property_rent','deduction')),
 person_id uuid,property_id uuid,title text not null check(length(title) between 1 and 200),
 mode text not null check(mode in ('documents','manual')),details text not null default '' check(length(details)<=10000),
 created_at timestamptz not null default now(),
 foreign key(account_id,case_id) references public.irs_cases(account_id,id),
 foreign key(case_id,person_id) references public.case_people(case_id,person_id),
 foreign key(account_id,case_id,property_id) references public.property_assets(account_id,case_id,id),
 unique(account_id,case_id,id),
 check((category in ('property_sale','property_rent') and property_id is not null and person_id is null)
 or(category in ('employment','pension','independent','securities') and person_id is not null and property_id is null)
 or(category='deduction' and property_id is null))
);
create table public.documents (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,
 income_id uuid,kind text not null check(length(kind) between 1 and 150),file_name text not null check(length(file_name) between 1 and 250),
 storage_path text not null unique,mime_type text not null,file_size bigint not null check(file_size>0 and file_size<=10485760),
 state text not null default 'pending' check(state in ('pending','uploaded','reviewed','rejected')),
 uploaded_by uuid not null default auth.uid() references auth.users(id),created_at timestamptz not null default now(),
 foreign key(account_id,case_id) references public.irs_cases(account_id,id),
 foreign key(account_id,case_id,income_id) references public.income_records(account_id,case_id,id),
 check(storage_path=account_id::text||'/'||case_id::text||'/'||id::text)
);
create table public.messages (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,
 author_id uuid not null default auth.uid() references auth.users(id),
 body text not null check(length(trim(body)) between 1 and 5000),created_at timestamptz not null default now(),
 foreign key(account_id,case_id) references public.irs_cases(account_id,id)
);
create table public.progress_events (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,
 author_id uuid not null default auth.uid() references auth.users(id),
 title text not null check(length(title) between 1 and 200),body text not null check(length(body) between 1 and 5000),
 created_at timestamptz not null default now(),foreign key(account_id,case_id) references public.irs_cases(account_id,id)
);
create table public.invoices (
 id uuid primary key default gen_random_uuid(),account_id uuid not null references public.client_accounts(id),
 reference text not null,issued_at date not null,due_at date,total numeric(12,2) not null check(total>=0),currency text not null default 'EUR' check(currency='EUR'),
 created_at timestamptz not null default now()
);
create table public.payments (
 id uuid primary key default gen_random_uuid(),account_id uuid not null references public.client_accounts(id),
 invoice_id uuid not null references public.invoices(id),amount numeric(12,2) not null check(amount>0),paid_at date not null,
 foreign key(invoice_id) references public.invoices(id),created_at timestamptz not null default now()
);
alter table public.invoices add constraint invoice_account_id unique(account_id,id);
alter table public.payments add constraint payment_same_account foreign key(account_id,invoice_id) references public.invoices(account_id,id);
create table public.task_alerts (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,person_id uuid not null,
 kind text not null default 'tax_2fa',resolved_at timestamptz,
 created_at timestamptz not null default now(),foreign key(account_id,person_id) references public.people(account_id,id)
);
create unique index one_open_alert on public.task_alerts(account_id,person_id,kind) where resolved_at is null;
create table public.invitation_requests (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,person_id uuid not null,
 email text not null check(length(email) between 3 and 254),state text not null default 'requested' check(state in ('requested','cancelled')),
 requested_by uuid not null default auth.uid() references auth.users(id),created_at timestamptz not null default now(),
 foreign key(account_id,person_id) references public.people(account_id,id)
);
create unique index one_open_invite_request on public.invitation_requests(account_id,person_id) where state='requested';

-- Client writes are limited to the collection stage. Staff can review and correct.
create function public.can_edit_case(account uuid,caseid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.is_staff() or (public.can_read_account(account) and exists(select 1 from public.irs_cases where id=caseid and account_id=account and status in ('collecting','missing')))
$$;
create function public.sync_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,email,full_name,birth_date,nif,phone,address)
 values(new.id,new.email,coalesce(nullif(left(new.raw_user_meta_data->>'full_name',200),''),'Novo utilizador'),nullif(new.raw_user_meta_data->>'birth_date','')::date,nullif(new.raw_user_meta_data->>'nif',''),left(new.raw_user_meta_data->>'phone',30),left(new.raw_user_meta_data->>'address',400));
 return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.sync_profile();
-- Preserve existing Auth users when adopting an already configured development project.
insert into public.profiles(id,email,full_name)
 select id,coalesce(email,''),coalesce(nullif(left(raw_user_meta_data->>'full_name',200),''),'Utilizador') from auth.users on conflict(id) do nothing;

create function public.alert_tax_2fa() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.tax_two_factor and (tg_op='INSERT' or not old.tax_two_factor) then
 insert into public.task_alerts(account_id,person_id) values(new.account_id,new.id) on conflict do nothing;
 end if; return new;
end $$;
create trigger tax_2fa_alert after insert or update of tax_two_factor on public.people for each row execute function public.alert_tax_2fa();

create function public.approve_client(client uuid,account_name text,year integer) returns uuid language plpgsql security definer set search_path='' as $$
declare account uuid; person uuid; process uuid; profile public.profiles;
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501';end if;
 select * into strict profile from public.profiles where id=client;
 if profile.birth_date is null or profile.nif is null then raise exception 'Complete registration data is required';end if;
 insert into public.client_accounts(name) values(account_name) returning id into account;
 insert into public.account_access(account_id,user_id,role,irs) values(account,client,'owner',true);
 insert into public.people(account_id,full_name,birth_date,nif,email) values(account,profile.full_name,profile.birth_date,profile.nif,profile.email) returning id into person;
 insert into public.irs_cases(account_id,tax_year) values(account,year) returning id into process;
 insert into public.case_people(account_id,case_id,person_id,relationship) values(account,process,person,'titular');
 return account;
end $$;
create function public.add_case_person(account uuid,process uuid,person_name text,birth date,tax_id text,relation text,person_email text,two_factor boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare person uuid;
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501';end if;
 insert into public.people(account_id,full_name,birth_date,nif,email,tax_two_factor) values(account,person_name,birth,tax_id,nullif(person_email,''),two_factor) returning id into person;
 insert into public.case_people(account_id,case_id,person_id,relationship) values(account,process,person,relation);
 return person;
end $$;
create function public.submit_case(account uuid,process uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501';end if;
 if not exists(select 1 from public.case_people where case_id=process and account_id=account and relationship='titular') then raise exception 'Holder is required';end if;
 update public.irs_cases set status='review' where id=process and account_id=account and status in ('collecting','missing');
end $$;

create function public.publish_case_progress(account uuid,process uuid,event_title text,event_body text,new_status text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501';end if;
 update public.irs_cases set status=new_status where id=process and account_id=account;
 if not found then raise exception 'Process not found';end if;
 insert into public.progress_events(account_id,case_id,author_id,title,body) values(account,process,auth.uid(),event_title,event_body);
end $$;

-- Default deny for authenticated users; per-table policies follow.
do $$ declare tab text; begin
 foreach tab in array array['profiles','staff_users','client_accounts','account_access','people','irs_cases','case_people','property_assets','income_records','documents','messages','progress_events','invoices','payments','task_alerts','invitation_requests'] loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('revoke all on public.%I from anon, authenticated',tab);
 execute format('grant select on public.%I to authenticated',tab);
 end loop;
end $$;
create policy profiles_read on public.profiles for select to authenticated using(id=(select auth.uid()) or public.is_staff());
create policy staff_read on public.staff_users for select to authenticated using(user_id=(select auth.uid()));
create policy account_read on public.client_accounts for select to authenticated using(public.can_read_account(id));
create policy access_read on public.account_access for select to authenticated using(user_id=(select auth.uid()) or public.is_staff());
-- Only staff can grant access or change lifecycle states.
grant update on public.account_access,public.client_accounts,public.irs_cases to authenticated;
create policy access_manage on public.account_access for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy account_manage on public.client_accounts for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy case_manage on public.irs_cases for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy person_read on public.people for select to authenticated using(public.can_read_account(account_id));
-- Do not expose arbitrary person creation or account reassignment: use add_case_person.
grant update(tax_two_factor,email) on public.people to authenticated;
create policy person_update on public.people for update to authenticated using(public.can_read_account(account_id)) with check(public.can_read_account(account_id));
create policy case_read on public.irs_cases for select to authenticated using(public.can_read_account(account_id));
create policy case_person_read on public.case_people for select to authenticated using(public.can_read_account(account_id));
do $$ declare tab text; begin
 foreach tab in array array['property_assets','income_records','documents'] loop
 execute format('create policy resource_read on public.%I for select to authenticated using(public.can_read_account(account_id))',tab);
 execute format('grant insert on public.%I to authenticated',tab);
 execute format('create policy resource_insert on public.%I for insert to authenticated with check(public.can_edit_case(account_id,case_id))',tab);
 end loop;
end $$;
grant update(state) on public.documents to authenticated;
create policy document_update on public.documents for update to authenticated using(public.can_edit_case(account_id,case_id) and uploaded_by=(select auth.uid())) with check(public.can_edit_case(account_id,case_id) and uploaded_by=(select auth.uid()) and state='uploaded');
-- Reject spoofed authors even where table INSERT is allowed.
create policy document_author on public.documents as restrictive for insert to authenticated with check(uploaded_by=(select auth.uid()) and state='pending');
grant insert on public.messages to authenticated;
create policy message_read on public.messages for select to authenticated using(public.can_read_account(account_id));
create policy message_insert on public.messages for insert to authenticated with check(public.can_read_account(account_id) and author_id=(select auth.uid()));
create policy progress_read on public.progress_events for select to authenticated using(public.can_read_account(account_id));
grant insert on public.progress_events to authenticated;
create policy progress_write on public.progress_events for insert to authenticated with check(public.is_staff() and author_id=(select auth.uid()));
create policy invoice_read on public.invoices for select to authenticated using(public.can_read_account(account_id));
create policy payment_read on public.payments for select to authenticated using(public.can_read_account(account_id));
create policy alert_read on public.task_alerts for select to authenticated using(public.is_staff());
grant update(resolved_at) on public.task_alerts to authenticated;
create policy alert_manage on public.task_alerts for update to authenticated using(public.is_staff()) with check(public.is_staff());
create policy invite_read on public.invitation_requests for select to authenticated using(public.can_read_account(account_id));
grant insert on public.invitation_requests to authenticated;
create policy invite_request on public.invitation_requests for insert to authenticated with check(public.can_read_account(account_id) and requested_by=(select auth.uid()));

revoke all on function public.is_staff(),public.can_read_account(uuid),public.can_edit_case(uuid,uuid),public.approve_client(uuid,text,integer),public.add_case_person(uuid,uuid,text,date,text,text,text,boolean),public.submit_case(uuid,uuid),public.publish_case_progress(uuid,uuid,text,text,text) from public;
grant execute on function public.is_staff(),public.can_read_account(uuid),public.can_edit_case(uuid,uuid),public.approve_client(uuid,text,integer),public.add_case_person(uuid,uuid,text,date,text,text,text,boolean),public.submit_case(uuid,uuid),public.publish_case_progress(uuid,uuid,text,text,text) to authenticated;
revoke all on function public.sync_profile(),public.alert_tax_2fa() from public;

-- Private object access tied to an authorized database document, not just a folder name.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('irs-documents','irs-documents',false,10485760,array['application/pdf','image/jpeg','image/png']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy irs_file_read on storage.objects for select to authenticated using(bucket_id='irs-documents' and exists(select 1 from public.documents d where d.storage_path=name and d.state in ('uploaded','reviewed') and public.can_read_account(d.account_id)));
create policy irs_file_insert on storage.objects for insert to authenticated with check(bucket_id='irs-documents' and exists(select 1 from public.documents d where d.storage_path=name and d.state='pending' and d.uploaded_by=(select auth.uid()) and public.can_edit_case(d.account_id,d.case_id)));
create index on public.account_access(user_id);
create index on public.irs_cases(account_id);
create index on public.people(account_id);
create index on public.income_records(case_id);
create index on public.documents(case_id);
create index on public.messages(case_id,created_at);
create index on public.progress_events(case_id,created_at);

-- Source: 202610230002_legal_acceptances.sql
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

-- Source: 202610230003_production_legal_version.sql
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

-- Source: 202610230004_annual_cases.sql
-- Shared production schema: apply once, after migrations 001–003.

create function public.create_irs_case(account uuid, year integer) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 account_state text; owner_id uuid; holder uuid; process uuid;
 owner_count integer; process_count integer;
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501'; end if;
 if year is null or year not between 2000 and 2100 then
  raise exception 'Invalid tax year' using errcode='22023';
 end if;
 -- Serialize all openings for this account, including concurrent retries.
 select ca.status into account_state from public.client_accounts ca where ca.id=account for update;
 if account_state is distinct from 'active' then
  raise exception 'An active account is required' using errcode='22023';
 end if;
 select count(*) into owner_count from public.account_access aa
 where aa.account_id=account and aa.role='owner' and aa.active and aa.irs;
 if owner_count<>1 then raise exception 'Exactly one active IRS owner is required' using errcode='22023'; end if;
 select aa.user_id into owner_id from public.account_access aa
 where aa.account_id=account and aa.role='owner' and aa.active and aa.irs;
 select count(*) into process_count from public.irs_cases c where c.account_id=account and c.tax_year=year;
 if process_count>1 then raise exception 'Existing annual cases need professional review' using errcode='22023'; end if;
 if process_count=1 then
  select c.id into process from public.irs_cases c where c.account_id=account and c.tax_year=year;
  return process;
 end if;
 select p.id into holder from public.people p join public.profiles pr on pr.nif=p.nif
 where p.account_id=account and pr.id=owner_id;
 if holder is null then raise exception 'The registered account holder is required' using errcode='22023'; end if;
 insert into public.irs_cases(account_id,tax_year) values(account,year) returning id into process;
 insert into public.case_people(account_id,case_id,person_id,relationship) values(account,process,holder,'titular');
 return process;
end $$;

create or replace function public.approve_client(client uuid,account_name text,year integer) returns uuid
language plpgsql security definer set search_path='' as $$
declare account uuid; owner_count integer; profile public.profiles;
begin
 if not public.is_staff() then raise exception 'Not authorized' using errcode='42501'; end if;
 if year is null or year not between 2000 and 2100 or account_name is null
    or length(btrim(account_name)) not between 1 and 200 then
  raise exception 'Invalid approval data' using errcode='22023';
 end if;
 -- The profile lock also covers retries with a different account name or year.
 select * into strict profile from public.profiles where id=client for update;
 select count(*) into owner_count from public.account_access aa where aa.user_id=client and aa.role='owner';
 if owner_count>1 then raise exception 'Select an existing account explicitly' using errcode='22023'; end if;
 if owner_count=1 then
  select aa.account_id into account from public.account_access aa where aa.user_id=client and aa.role='owner';
  -- Approval retries never change grants, reactivate accounts or open another year.
  return account;
 end if;
 if profile.birth_date is null or profile.birth_date>current_date or profile.nif is null then
  raise exception 'Complete registration data is required' using errcode='22023';
 end if;
 insert into public.client_accounts(name) values(btrim(account_name)) returning id into account;
 insert into public.account_access(account_id,user_id,role,irs) values(account,client,'owner',true);
 insert into public.people(account_id,full_name,birth_date,nif,email)
 values(account,profile.full_name,profile.birth_date,profile.nif,profile.email);
 perform public.create_irs_case(account,year);
 return account;
end $$;

create function public.link_case_person(account uuid,process uuid,person uuid,relation text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501'; end if;
 if relation is null or relation not in ('conjuge','descendente','ascendente','outro') then
  raise exception 'Invalid household relationship' using errcode='22023';
 end if;
 -- Recheck after locking, to avoid linking to a case which has just entered review.
 perform 1 from public.irs_cases c where c.id=process and c.account_id=account for update;
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501'; end if;
 if not exists(select 1 from public.people p where p.id=person and p.account_id=account) then
  raise exception 'Person not found in this account' using errcode='22023';
 end if;
 if exists(select 1 from public.case_people cp where cp.case_id=process and cp.person_id=person and cp.relationship<>relation) then
  raise exception 'Person already has a relationship in this case' using errcode='22023';
 end if;
 insert into public.case_people(account_id,case_id,person_id,relationship)
 values(account,process,person,relation) on conflict(case_id,person_id) do nothing;
end $$;

revoke all on function public.link_case_person(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.link_case_person(uuid,uuid,uuid,text) to authenticated;
revoke all on function public.create_irs_case(uuid,integer) from public,anon;
grant execute on function public.create_irs_case(uuid,integer) to authenticated;
revoke all on function public.approve_client(uuid,text,integer) from public,anon;
grant execute on function public.approve_client(uuid,text,integer) to authenticated;

-- Source: 202610230005_accounts_and_management.sql
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

-- Source: 202610230006_checkout.sql
create table public.discount_codes (
 id uuid primary key default gen_random_uuid(),code text not null unique check(code ~ '^[A-Z0-9_-]{3,40}$'),
 kind text not null check(kind in ('fixed','percentage')),value integer not null check(value>0),
 active boolean not null default true,allowed_user uuid references public.profiles(id),starts_at timestamptz,ends_at timestamptz,
 max_uses integer check(max_uses>0),created_at timestamptz not null default now(),
 check(kind<>'percentage' or value<=10000),check(ends_at is null or starts_at is null or ends_at>starts_at)
);
alter table public.profiles add column irs_free boolean not null default false, add column forced_discount_id uuid references public.discount_codes(id);
alter table public.discount_codes enable row level security;
revoke all on public.discount_codes from anon,authenticated;
grant select,insert,update on public.discount_codes to authenticated;
create policy discount_manage on public.discount_codes for all to authenticated using(public.is_staff()) with check(public.is_staff());

create function public.set_client_billing(target uuid,free_service boolean,required_discount uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_staff() or target=auth.uid() then raise exception 'Not authorized' using errcode='42501';end if;
 update public.profiles set irs_free=free_service,forced_discount_id=required_discount where id=target and deleted_at is null;
 if not found then raise exception 'User unavailable';end if;
 insert into public.management_audit(actor_id,target_id,action) values(auth.uid(),target,'billing_preferences_updated');
end $$;
revoke all on function public.set_client_billing(uuid,boolean,uuid) from public,anon;
grant execute on function public.set_client_billing(uuid,boolean,uuid) to authenticated;

create table public.irs_checkouts (
 id uuid primary key default gen_random_uuid(),account_id uuid not null,case_id uuid not null,user_id uuid not null references public.profiles(id),
 state text not null default 'creating' check(state in ('creating','pending','unknown','paid','failed','cancelled')),
 provider_order_id text unique,checkout_url text,quote jsonb not null,amount_cents integer not null check(amount_cents>=0),currency text not null default 'EUR' check(currency='EUR'),
 discount_id uuid references public.discount_codes(id),discount_cents integer not null default 0 check(discount_cents>=0),
 created_at timestamptz not null default now(),paid_at timestamptz,last_checked_at timestamptz,
 foreign key(account_id,case_id) references public.irs_cases(account_id,id)
);
create unique index one_live_checkout on public.irs_checkouts(case_id) where state in ('creating','pending','unknown','paid');
create index checkouts_discount on public.irs_checkouts(discount_id,state);
alter table public.irs_checkouts enable row level security;
revoke all on public.irs_checkouts from anon,authenticated;
grant select on public.irs_checkouts to authenticated;
grant select,update on public.irs_checkouts to service_role;
create policy checkout_read on public.irs_checkouts for select to authenticated using(public.can_read_account(account_id));

create function public.price_irs_case(account uuid,process uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare items jsonb:='[{"code":"base","label":"Preparação IRS — primeiro tipo de rendimento (IVA incluído)","amount_cents":1850}]';
 total integer:=1850; workers integer; sales integer; rents integer; has_a boolean; has_b boolean; has_h boolean; has_g boolean; kinds integer; amount integer;
begin
 if not public.can_read_account(account) or not exists(select 1 from public.irs_cases c where c.id=process and c.account_id=account) then raise exception 'Not authorized' using errcode='42501';end if;
 select count(distinct person_id) filter(where category in ('employment','pension')),
 count(distinct property_id) filter(where category='property_sale'),count(distinct property_id) filter(where category='property_rent'),
 coalesce(bool_or(category='employment'),false),coalesce(bool_or(category='independent'),false),coalesce(bool_or(category='pension'),false),coalesce(bool_or(category='securities'),false),
 count(distinct category) filter(where category<>'deduction')
 into workers,sales,rents,has_a,has_b,has_h,has_g,kinds from public.income_records where account_id=account and case_id=process;
 if kinds=0 then raise exception 'Add at least one income type' using errcode='22023';end if;
 if workers>1 then items:=items||jsonb_build_array(jsonb_build_object('code','household_work','label','Várias pessoas com trabalho ou pensões','amount_cents',500));total:=total+500;end if;
 if has_a and has_b then items:=items||jsonb_build_array(jsonb_build_object('code','a_and_b','label','Acumulação de categorias A e B','amount_cents',1500));total:=total+1500;
 elsif has_h and has_b then items:=items||jsonb_build_array(jsonb_build_object('code','additional_b','label','Categoria B adicional às pensões','amount_cents',500));total:=total+500;end if;
 if rents>0 then
  amount:=case when rents<=2 then case when kinds=1 then 0 else 500 end when rents<=5 then 1000 else 2000 end;
  items:=items||jsonb_build_array(jsonb_build_object('code','rents','label','Rendas — '||rents||' imóvel(is)','amount_cents',amount));total:=total+amount;
 end if;
 if has_g then
  amount:=1000;
  items:=items||jsonb_build_array(jsonb_build_object('code','securities','label','Mais-valias de ações e outros títulos — categoria G','amount_cents',amount));total:=total+amount;
 end if;
 if sales>0 then
  amount:=1000*sales;
  items:=items||jsonb_build_array(jsonb_build_object('code','property_sales','label','Mais-valias de imóveis — '||sales||' imóvel(is)','amount_cents',amount));total:=total+amount;
 end if;
 return jsonb_build_object('version','2026-10-23.1','currency','EUR','items',items,'subtotal_cents',total,'vat_included',true);
end $$;

create function public.quote_irs_checkout(account uuid,process uuid,coupon text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare quote jsonb; discount public.discount_codes; reduction integer:=0; total integer; used integer; billing public.profiles;
begin
 quote:=public.price_irs_case(account,process);total:=(quote->>'subtotal_cents')::integer;
 select p.* into strict billing from public.profiles p join public.account_access a on a.user_id=p.id where a.account_id=account and a.role='owner';
 if billing.irs_free then return quote||jsonb_build_object('discount_id',null,'discount_code','CLIENTE GRATUITO','discount_cents',total,'total_cents',0);end if;
 if billing.forced_discount_id is not null then
  select code into coupon from public.discount_codes where id=billing.forced_discount_id;
  if coupon is null then raise exception 'Required discount unavailable';end if;
 end if;
 if btrim(coalesce(coupon,''))<>'' then
  select * into discount from public.discount_codes where code=upper(btrim(coupon));
  if not found then raise exception 'Discount unavailable' using errcode='22023';end if;
  select count(*) into used from public.irs_checkouts where discount_id=discount.id and state in ('creating','pending','unknown','paid');
  if not discount.active or (discount.allowed_user is not null and discount.allowed_user<>billing.id)
   or (discount.starts_at is not null and discount.starts_at>now()) or (discount.ends_at is not null and discount.ends_at<=now())
   or (discount.max_uses is not null and used>=discount.max_uses) then raise exception 'Discount unavailable' using errcode='22023';end if;
  reduction:=least(total,case when discount.kind='fixed' then discount.value else ((total::bigint*discount.value+5000)/10000)::integer end);
 end if;
 return quote||jsonb_build_object('discount_id',discount.id,'discount_code',discount.code,'discount_cents',reduction,'total_cents',total-reduction);
end $$;

create function public.begin_irs_checkout(account uuid,process uuid,coupon text default '',expected_total integer default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare quote jsonb; attempt public.irs_checkouts;
begin
 if not public.can_read_account(account) or not exists(select 1 from public.account_access a where a.account_id=account and a.user_id=auth.uid() and a.role='owner' and a.active and a.irs) then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.irs_cases c where c.id=process and c.account_id=account for update;
 if not found then raise exception 'Process unavailable';end if;
 select * into attempt from public.irs_checkouts where case_id=process and state in ('creating','pending','unknown','paid');
 if found then return jsonb_build_object('id',attempt.id,'state',attempt.state,'checkout_url',attempt.checkout_url,'created',false,'amount_cents',attempt.amount_cents);end if;
 if not exists(select 1 from public.irs_cases c where c.id=process and c.status in ('collecting','missing')) then raise exception 'Case is not collecting';end if;
 if not exists(select 1 from public.case_people where case_id=process and relationship='titular') then raise exception 'Holder missing';end if;
 if exists(select 1 from public.documents where case_id=process and state='pending') then raise exception 'Finish pending uploads first';end if;
 -- Lock discounts before checking the global usage cap, including other accounts.
 perform 1 from public.discount_codes d where d.code=upper(btrim(coalesce(coupon,''))) or d.id=(select p.forced_discount_id from public.profiles p where p.id=auth.uid()) order by d.id for update;
 quote:=public.quote_irs_checkout(account,process,coupon);
 if expected_total is not null and expected_total<>(quote->>'total_cents')::integer then raise exception 'Price changed. Review the quote again.' using errcode='22023';end if;
 insert into public.irs_checkouts(account_id,case_id,user_id,quote,amount_cents,discount_id,discount_cents)
 values(account,process,auth.uid(),quote,(quote->>'total_cents')::integer,(quote->>'discount_id')::uuid,(quote->>'discount_cents')::integer) returning * into attempt;
 if attempt.amount_cents=0 then
  update public.irs_checkouts set state='paid',paid_at=now() where id=attempt.id;
  update public.irs_cases set status='review' where id=process;
  insert into public.progress_events(account_id,case_id,author_id,title,body) values(account,process,auth.uid(),'Processo recebido','Processo enviado para revisão com desconto integral. Não representa submissão à AT.');
 end if;
 return jsonb_build_object('id',attempt.id,'state',case when attempt.amount_cents=0 then 'paid' else 'creating' end,'created',true,'amount_cents',attempt.amount_cents);
end $$;

create function public.attach_revolut_order(attempt uuid,provider_id text,provider_url text) returns void language plpgsql security definer set search_path='' as $$
begin
 if provider_id is null or length(provider_id)>200 then raise exception 'Invalid order';end if;
 update public.irs_checkouts set provider_order_id=provider_id,checkout_url=provider_url,state='pending' where id=attempt and state in ('creating','unknown') and provider_order_id is null;
 if not found then raise exception 'Checkout already attached';end if;
end $$;
create function public.finish_revolut_order(attempt uuid,provider_id text,provider_reference text,provider_state text,provider_amount integer,provider_currency text) returns void language plpgsql security definer set search_path='' as $$
declare payment public.irs_checkouts;
begin
 select * into strict payment from public.irs_checkouts where id=attempt for update;
 if payment.provider_order_id is distinct from provider_id or payment.id::text is distinct from provider_reference
 or payment.amount_cents is distinct from provider_amount or provider_currency is distinct from 'EUR' then raise exception 'Order mismatch';end if;
 if payment.state='paid' then return;end if;
 if payment.state not in ('pending','unknown') then raise exception 'Invalid payment state';end if;
 update public.irs_checkouts set last_checked_at=now() where id=attempt;
 if provider_state='COMPLETED' then
  update public.irs_checkouts set state='paid',paid_at=now() where id=attempt;
  update public.irs_cases set status='review' where id=payment.case_id and status in ('collecting','missing');
  insert into public.progress_events(account_id,case_id,author_id,title,body) values(payment.account_id,payment.case_id,payment.user_id,'Pagamento confirmado','Processo recebido para revisão pelo contabilista. A declaração ainda não foi submetida à AT.');
 elsif provider_state in ('CANCELLED','FAILED') then
  update public.irs_checkouts set state=case when provider_state='CANCELLED' then 'cancelled' else 'failed' end where id=attempt;
 end if;
end $$;
revoke all on function public.price_irs_case(uuid,uuid),public.quote_irs_checkout(uuid,uuid,text),public.begin_irs_checkout(uuid,uuid,text,integer) from public,anon;
grant execute on function public.price_irs_case(uuid,uuid),public.quote_irs_checkout(uuid,uuid,text),public.begin_irs_checkout(uuid,uuid,text,integer) to authenticated;
revoke all on function public.attach_revolut_order(uuid,text,text),public.finish_revolut_order(uuid,text,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.attach_revolut_order(uuid,text,text),public.finish_revolut_order(uuid,text,text,text,integer,text) to service_role;
create or replace function public.can_edit_case(account uuid,caseid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.is_staff() or (public.can_read_account(account) and exists(select 1 from public.irs_cases c where c.id=caseid and c.account_id=account and c.status in ('collecting','missing'))
 and not exists(select 1 from public.irs_checkouts p where p.case_id=caseid and p.state in ('creating','pending','unknown')))
$$;
create or replace function public.submit_case(account uuid,process uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501';end if;
 if not public.is_staff() and not exists(select 1 from public.irs_checkouts where case_id=process and state='paid') then raise exception 'Confirmed payment required';end if;
 if not exists(select 1 from public.case_people where case_id=process and account_id=account and relationship='titular') then raise exception 'Holder required';end if;
 update public.irs_cases set status='review' where id=process and account_id=account and status in ('collecting','missing');
end $$;

create function public.guard_case_collection() returns trigger language plpgsql security definer set search_path='' as $$
declare target_case uuid; target_account uuid;
begin
 if tg_op='DELETE' then target_case:=old.case_id;target_account:=old.account_id;else target_case:=new.case_id;target_account:=new.account_id;end if;
 perform 1 from public.irs_cases c where c.id=target_case and c.account_id=target_account for update;
 if not public.can_edit_case(target_account,target_case) or exists(select 1 from public.irs_checkouts p where p.case_id=target_case and p.state in ('creating','pending','unknown')) then raise exception 'Collection locked' using errcode='42501';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function public.guard_case_collection() from public,anon,authenticated;
create trigger guard_case_collection before insert or update or delete on public.case_people for each row execute function public.guard_case_collection();
create trigger guard_case_collection before insert or update or delete on public.income_records for each row execute function public.guard_case_collection();
create trigger guard_case_collection before insert or update or delete on public.property_assets for each row execute function public.guard_case_collection();
create trigger guard_case_collection before insert or update or delete on public.documents for each row execute function public.guard_case_collection();

-- Source: 202610230007_document_deduplication.sql
-- Originals stay in private object storage; Postgres stores only metadata and SHA-256.
alter table public.documents add column content_hash text check(content_hash ~ '^[a-f0-9]{64}$');
alter table public.documents drop constraint documents_storage_path_key,drop constraint documents_check;
alter table public.documents add constraint document_path_same_case check(
 storage_path ~ ('^'||account_id::text||'/'||case_id::text||'/[a-f0-9-]{36}$'));
create index documents_content_lookup on public.documents(account_id,case_id,content_hash);
create function public.prepare_irs_document(account uuid,process uuid,record uuid,doc_kind text,original_name text,mime text,size_bytes bigint,hash text)
 returns jsonb language plpgsql security definer set search_path='' as $$
declare existing public.documents; document_id uuid:=gen_random_uuid(); path text; reuse boolean:=false;
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501';end if;
 if hash is null or hash !~ '^[a-f0-9]{64}$' or mime not in ('application/pdf','image/jpeg','image/png') or size_bytes is null or size_bytes not between 1 and 10485760 then raise exception 'Invalid file';end if;
 perform pg_advisory_xact_lock(hashtextextended(account::text||process::text||hash,0));
 select * into existing from public.documents where account_id=account and case_id=process and content_hash=hash order by (state in ('uploaded','reviewed')) desc,created_at limit 1;
 if found then
  if existing.state not in ('uploaded','reviewed') then raise exception 'Identical file pending or rejected. Contact the professional.';end if;
  if existing.file_size<>size_bytes or existing.mime_type<>mime then raise exception 'File metadata mismatch';end if;
  path:=existing.storage_path;reuse:=true;
 else path:=account::text||'/'||process::text||'/'||document_id::text;
 end if;
 insert into public.documents(id,account_id,case_id,income_id,kind,file_name,storage_path,mime_type,file_size,content_hash)
 values(document_id,account,process,record,doc_kind,original_name,path,mime,size_bytes,hash);
 return jsonb_build_object('id',document_id,'path',path,'reused',reuse);
end $$;
revoke all on function public.prepare_irs_document(uuid,uuid,uuid,text,text,text,bigint,text) from public,anon;
grant execute on function public.prepare_irs_document(uuid,uuid,uuid,text,text,text,bigint,text) to authenticated;

-- Source: 202610240008_session_context.sql
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

-- Source: 202610240009_administration.sql
-- Separate administration, professional access and the IRS 2026 campaign.

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

-- Source: 202610250010_espaco_vistas.sql
-- Uma vista, uma ida à base de dados.
--
-- Antes, cada separador do portal disparava entre quatro e onze pedidos ao
-- PostgREST. Com as funções do Vercel em arn1 e o Supabase em eu-north-1 isso
-- ainda custava pouco, mas o custo multiplicava-se por cada mudança de
-- separador. Estas funções devolvem o ecrã inteiro num único JSON.
--
-- São `security invoker`: a autorização continua a ser feita pelas políticas de
-- RLS já existentes, não por verificações repetidas aqui dentro.


create or replace function public.espaco_irs(vista text, processo uuid default null)
returns jsonb language plpgsql stable as $$
declare conta uuid; eu uuid := auth.uid(); dados jsonb := '{}'::jsonb;
begin
  if eu is null then raise exception 'Autenticação necessária' using errcode='42501'; end if;

  if processo is not null then
    -- A RLS decide o que é visível. Se não vier nada, o processo não é desta conta.
    select account_id into conta from public.irs_cases where id = processo;
    if conta is null then raise exception 'Processo indisponível' using errcode='42501'; end if;
  end if;

  if processo is null then return jsonb_build_object('vista', vista); end if;

  if vista = 'resumo' then
    dados := jsonb_build_object(
      'pessoas', (select count(*) from public.case_people where case_id = processo),
      'rendimentos', (select count(*) from public.income_records where case_id = processo and category <> 'deduction'),
      'despesas', (select count(*) from public.income_records where case_id = processo and category = 'deduction'),
      'documentos', (select count(*) from public.documents where case_id = processo and state <> 'pending'),
      'mensagens', (select count(*) from public.messages where case_id = processo),
      'ultimo_progresso', (select to_jsonb(p) from (
        select title, body, created_at from public.progress_events
        where case_id = processo order by created_at desc limit 1) p),
      'ultima_mensagem', (select to_jsonb(m) from (
        select body, author_id = eu as minha, created_at from public.messages
        where case_id = processo order by created_at desc limit 1) m),
      'pagamento', (select to_jsonb(c) from (
        select id, state, amount_cents, paid_at, created_at from public.irs_checkouts
        where case_id = processo order by created_at desc limit 1) c));

  elsif vista = 'agregado' then
    dados := jsonb_build_object(
      'pessoas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.ordem, p.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, pe.birth_date, pe.nif, pe.email, pe.tax_two_factor,
               cp.relationship,
               case cp.relationship when 'titular' then 0 when 'conjuge' then 1
                 when 'descendente' then 2 when 'ascendente' then 3 else 4 end as ordem
        from public.people pe
        join public.case_people cp on cp.person_id = pe.id and cp.case_id = processo) p),
      'disponiveis', (select coalesce(jsonb_agg(to_jsonb(d) order by d.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, pe.nif from public.people pe
        where pe.account_id = conta
          and not exists (select 1 from public.case_people cp where cp.case_id = processo and cp.person_id = pe.id)) d),
      'convites', (select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at desc), '[]'::jsonb) from (
        select id, person_id, email, state, expires_at, accepted_at, created_at
        from public.household_invitations where account_id = conta) i));

  elsif vista = 'rendimentos' then
    dados := jsonb_build_object(
      'rendimentos', (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]'::jsonb) from (
        select i.id, i.title, i.category, i.person_id, i.property_id, i.mode, i.details, i.created_at,
               (select count(*) from public.documents d where d.income_id = i.id and d.state <> 'pending') as documentos
        from public.income_records i where i.case_id = processo) r),
      'imoveis', (select coalesce(jsonb_agg(to_jsonb(v) order by v.label), '[]'::jsonb) from (
        select id, label, description from public.property_assets where case_id = processo) v),
      'pessoas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, cp.relationship from public.people pe
        join public.case_people cp on cp.person_id = pe.id and cp.case_id = processo) p));

  elsif vista = 'documentos' then
    dados := jsonb_build_object(
      'documentos', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from (
        select dc.id, dc.kind, dc.file_name, dc.state, dc.income_id, dc.file_size, dc.mime_type, dc.created_at,
               dc.uploaded_by = eu as meu, i.title as rendimento, i.category
        from public.documents dc
        left join public.income_records i on i.id = dc.income_id
        where dc.case_id = processo and dc.state <> 'pending') d),
      'rendimentos', (select coalesce(jsonb_agg(to_jsonb(r) order by r.title), '[]'::jsonb) from (
        select id, title, category from public.income_records where case_id = processo) r));

  elsif vista = 'mensagens' then
    -- Sem nomes: o cliente não lê o perfil do contabilista nem o contrário.
    -- Cada lado sabe quem é o outro pelo contexto do ecrã.
    dados := jsonb_build_object(
      'mensagens', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from (
        select id, body, author_id = eu as minha, created_at
        from public.messages where case_id = processo
        order by created_at desc limit 200) m));

  elsif vista = 'progresso' then
    dados := jsonb_build_object(
      'eventos', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from (
        select id, title, body, created_at from public.progress_events
        where case_id = processo order by created_at desc limit 100) p));

  elsif vista = 'pagamento' then
    dados := jsonb_build_object(
      'tentativas', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) from (
        select id, state, amount_cents, discount_cents, quote, checkout_url, paid_at, created_at
        from public.irs_checkouts where case_id = processo order by created_at desc limit 20) c),
      'faturas', (select coalesce(jsonb_agg(to_jsonb(f) order by f.issued_at desc), '[]'::jsonb) from (
        select i.id, i.reference, i.issued_at, i.due_at, i.total, i.currency,
               coalesce((select sum(p.amount) from public.payments p where p.invoice_id = i.id), 0) as pago
        from public.invoices i where i.account_id = conta) f));

  else
    raise exception 'Vista desconhecida: %', vista using errcode='22023';
  end if;

  return dados || jsonb_build_object('vista', vista, 'processo', processo);
end $$;

revoke all on function public.espaco_irs(text, uuid) from public, anon;
grant execute on function public.espaco_irs(text, uuid) to authenticated;


-- Ecrã do contabilista. A mesma ideia, mas atravessa todos os clientes.
create or replace function public.espaco_gabinete(vista text, processo uuid default null)
returns jsonb language plpgsql stable as $$
declare eu uuid := auth.uid();
begin
  if eu is null or not public.is_staff() then
    raise exception 'Apenas o contabilista acede a este espaço' using errcode='42501';
  end if;

  if vista = 'fila' then
    return jsonb_build_object('vista', vista,
      'processos', (select coalesce(jsonb_agg(to_jsonb(p) order by p.ordem, p.created_at), '[]'::jsonb) from (
        select c.id, c.account_id, c.status, c.created_at, a.name as cliente,
               case c.status when 'review' then 0 when 'validation' then 1 when 'authorization' then 2
                 when 'missing' then 3 when 'collecting' then 4 when 'submitted' then 5 else 6 end as ordem,
               (select count(*) from public.documents d where d.case_id = c.id and d.state = 'uploaded') as por_rever,
               (select count(*) from public.messages m where m.case_id = c.id and m.author_id <> eu) as mensagens_cliente,
               (select max(m.created_at) from public.messages m where m.case_id = c.id) as ultima_mensagem,
               (select x.state from public.irs_checkouts x where x.case_id = c.id order by x.created_at desc limit 1) as pagamento
        from public.irs_cases c join public.client_accounts a on a.id = c.account_id
        where c.campaign = 2026) p),
      'resumo', jsonb_build_object(
        'total', (select count(*) from public.irs_cases where campaign = 2026),
        'a_rever', (select count(*) from public.irs_cases where campaign = 2026 and status in ('review','validation','authorization')),
        'em_recolha', (select count(*) from public.irs_cases where campaign = 2026 and status = 'collecting'),
        'submetidos', (select count(*) from public.irs_cases where campaign = 2026 and status in ('submitted','completed')),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null)));

  elsif vista = 'alertas' then
    return jsonb_build_object('vista', vista,
      'alertas', (select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc), '[]'::jsonb) from (
        select t.id, t.kind, t.created_at, p.full_name as pessoa, c.name as cliente, t.account_id
        from public.task_alerts t
        join public.people p on p.id = t.person_id
        join public.client_accounts c on c.id = t.account_id
        where t.resolved_at is null) a));

  else
    -- Qualquer outra vista é a vista do cliente, vista de fora.
    return public.espaco_irs(vista, processo);
  end if;
end $$;

revoke all on function public.espaco_gabinete(text, uuid) from public, anon;
grant execute on function public.espaco_gabinete(text, uuid) to authenticated;

-- Source: 202610250011_ano_fiscal_2026.sql
-- A campanha IRS 2026 entrega-se em maio de 2027, logo o ano dos rendimentos
-- é 2026. Os processos tinham ficado com tax_year 2025, herdado de quando a
-- campanha era calculada a partir do ano corrente.
--
-- O `campaign` já era 2026 e é por ele que o portal filtra, por isso nada
-- estava partido — mas o ano fiscal gravado contradizia o que a plataforma
-- diz ao cliente.


update public.irs_cases set tax_year = 2026 where campaign = 2026 and tax_year <> 2026;

-- save_personal_profile abre o processo do cliente no primeiro acesso e tinha
-- o ano fixado em 2025. Reescreve-se o corpo em vez de o repetir aqui, para a
-- função não divergir do resto da sua definição.
do $ano$
declare definicao text;
begin
  select pg_get_functiondef(
    'public.save_personal_profile(text,date,text,text,text,text,text,boolean)'::regprocedure
  ) into definicao;

  if position('values(account,2025)' in definicao) = 0 then
    raise exception 'save_personal_profile já não fixa o ano em 2025; reveja a migração antes de a aplicar';
  end if;

  execute replace(definicao, 'values(account,2025)', 'values(account,2026)');
end $ano$;

-- Source: 202610250012_espaco_vistas_search_path.sql
-- As funções de vista tinham ficado sem search_path fixo, ao contrário de
-- todas as outras da base. Qualificam tudo com public. e auth., por isso o
-- resultado não muda — mas deixa de depender do search_path de quem chama,
-- que é o que o linter do Supabase assinala.
--
-- São `security invoker`, logo correm com os privilégios de quem chama e a
-- autorização continua a ser feita pelas políticas de RLS.


alter function public.espaco_irs(text, uuid) set search_path = '';
alter function public.espaco_gabinete(text, uuid) set search_path = '';

-- Source: 202610250013_desempenho.sql
-- Avisos de desempenho da auditoria do Supabase.
--
-- Nada disto se nota hoje, com um punhado de registos. Nota-se quando a
-- campanha encher: sem índice, cada verificação de chave estrangeira e cada
-- apagamento na tabela referenciada passa a varrer a tabela inteira.


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

-- Source: 202610250014_gatilhos_sem_execute.sql
-- Três funções de gatilho tinham EXECUTE aberto a anon e authenticated.
--
-- Não são chamáveis de forma útil — fora de um gatilho não há NEW nem OLD e a
-- chamada rebenta — mas apareciam expostas em /rest/v1/rpc/ sem razão. A
-- guard_case_collection, do mesmo tipo, já estava fechada: isto alinha as
-- outras pelo mesmo critério.
--
-- Revogar EXECUTE não impede os gatilhos de correr: um gatilho executa com os
-- privilégios do dono da tabela, não com os de quem fez a escrita.


revoke all on function public.sync_profile() from public, anon, authenticated;
revoke all on function public.capture_registration_acceptance() from public, anon, authenticated;
revoke all on function public.alert_tax_2fa() from public, anon, authenticated;

-- Source: 202610250015_politicas_leitura_unicas.sql
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

-- Source: 202610250016_documentos_em_webp.sql
-- Os documentos fiscais chegam quase sempre como fotografias de telemóvel:
-- 4000px de largura e vários megabytes para um recibo que se lê a 2600px.
-- A aplicação passa a convertê-las para WebP antes de as guardar, por isso o
-- balde tem de aceitar esse tipo. Os PDF continuam a entrar como vêm.


update storage.buckets
set allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp']
where id = 'irs-documents';

-- Source: 202610250017_definir_acessos.sql
-- Dar acesso de IRS ou de Empresas a um utilizador, criando a conta-cliente
-- quando ela ainda não existe.
--
-- O cliente de IRS cria-se a si próprio no registo, e nessa altura ganha conta
-- e acesso. O cliente de Empresas é criado pelo contabilista e pode nunca ter
-- tido conta nenhuma. Quando um quer o módulo do outro, é aqui que se resolve:
-- sem conta, cria-se; com conta, muda-se o que está marcado.
--
-- As empresas em si continuam a associar-se no módulo Empresas: isto marca
-- apenas que a pessoa tem acesso à plataforma.


create or replace function public.definir_acessos(target uuid, com_irs boolean, com_empresas boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare conta uuid; nome text;
begin
  if not public.is_platform_owner() then
    raise exception 'Apenas o administrador atribui acessos' using errcode = '42501';
  end if;
  if target is null or not exists (select 1 from public.profiles where id = target) then
    raise exception 'Utilizador desconhecido' using errcode = '22023';
  end if;

  select a.account_id into conta
  from public.account_access a
  where a.user_id = target and a.role = 'owner'
  limit 1;

  if conta is null then
    if not com_irs and not com_empresas then return null; end if;

    select coalesce(nullif(btrim(p.full_name), ''), p.email, 'Cliente')
      into nome from public.profiles p where p.id = target;

    insert into public.client_accounts(name) values (left(nome, 200)) returning id into conta;
    insert into public.account_access(account_id, user_id, role, irs, business, active)
    values (conta, target, 'owner', com_irs, com_empresas, true);
  else
    update public.account_access
    set irs = com_irs, business = com_empresas
    where account_id = conta and user_id = target;
  end if;

  insert into public.management_audit(actor_id, target_id, action)
  values (auth.uid(), target,
          'acessos: irs=' || com_irs::text || ' empresas=' || com_empresas::text);

  return conta;
end $$;

revoke all on function public.definir_acessos(uuid, boolean, boolean) from public, anon;
grant execute on function public.definir_acessos(uuid, boolean, boolean) to authenticated;

-- Source: 202610260018_plataforma_irs.sql
-- Esquema do pós-login do IRS: residência fiscal, senhas das Finanças com
-- registo de consultas, rendimentos com titular e sub-tipo, mais-valias,
-- deduções, notas por separador e o percurso do processo.

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

-- Source: 202610260019_estados_nas_funcoes.sql
-- A migracao anterior trocou o vocabulario dos estados do processo, mas havia
-- funcoes a escrever 'review' e a ler 'missing'/'completed'. Contra a
-- restricao nova, rebentavam em producao. Sao reescritas a partir da propria
-- definicao, para nao haver erros de transcricao.

do $rewrite$
declare
  f record;
  fonte text;
  pares text[][] := array[
    array['''collecting'',''missing''', ''''||'collecting'''],
    array['''collecting'', ''missing''', ''''||'collecting'''],
    array['''review''', '''submitted_by_client'''],
    array['''authorization''', '''approved'''],
    array['''completed''', '''closed'''],
    array['''submitted''', '''filed'''],
    array['''missing''', '''validation''']
  ];
  par text[];
begin
  for f in
    select p.oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ~ '''(review|missing|authorization|completed|submitted)'''
  loop
    fonte := pg_get_functiondef(f.oid);
    foreach par slice 1 in array pares loop
      fonte := replace(fonte, par[1], par[2]);
    end loop;
    execute fonte;
  end loop;
end $rewrite$;

-- Se sobrar algum literal antigo, a instalacao para aqui em vez de seguir
-- com funcoes que violam a restricao dos estados.
do $check$
declare n int;
begin
  select count(*) into n
  from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
  where nsp.nspname = 'public' and p.prokind = 'f'
    and pg_get_functiondef(p.oid) ~ '''(review|missing|authorization|completed)''';
  if n > 0 then
    raise exception 'Restam % funcoes com estados antigos.', n;
  end if;
end $check$;

-- Source: 202610260020_espaco_cliente.sql
-- O espaço do cliente: um separador, um pedido.
-- A função corre com as permissões de quem chama (security invoker), por isso
-- é a RLS que decide o que cada um vê — não há aqui nenhuma verificação de
-- acesso à mão que possa divergir das políticas.

create or replace function public.espaco_irs(vista text, processo uuid default null)  -- o default existia: tirá-lo obriga a DROP
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  conta uuid;
  dados jsonb := jsonb_build_object('vista', vista, 'processo', processo);
  membros jsonb;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then
    return dados || jsonb_build_object('erro', 'sem_acesso');
  end if;

  -- O agregado serve de base a quase tudo: os rendimentos escolhem titular,
  -- as deduções escolhem o titular do PPR.
  select coalesce(jsonb_agg(m order by m->>'ordem', m->>'nome'), '[]'::jsonb) into membros
  from (
    select jsonb_build_object(
      'id', p.id,
      'nome', p.full_name,
      'nascimento', p.birth_date,
      'nif', p.nif,
      'email', p.email,
      'relacao', cp.relationship,
      'dois_fatores', p.tax_two_factor,
      'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
      'senha_em', (select tc.updated_at from public.tax_credentials tc where tc.person_id = p.id),
      'ordem', case cp.relationship when 'titular' then '0' else '1' end
    ) as m
    from public.case_people cp
    join public.people p on p.id = cp.person_id
    where cp.case_id = processo
  ) t;

  if vista = 'agregado' then
    return dados || jsonb_build_object('membros', membros);
  end if;

  if vista = 'rendimentos' then
    return dados || jsonb_build_object(
      'membros', membros,
      'imoveis', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', pa.id, 'nome', pa.label, 'tipo', pa.kind, 'descricao', pa.description
        ) order by pa.label), '[]'::jsonb)
        from public.property_assets pa where pa.case_id = processo),
      'rendimentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', ir.id, 'categoria', ir.category, 'tipo', ir.kind, 'titulo', ir.title,
          'titular', ir.person_id, 'imovel', ir.property_id, 'valor', ir.amount_cents,
          'nota', ir.details, 'irs_jovem', ir.young_irs, 'estuda_trabalha', ir.studies_and_works,
          'ambito', ir.foreign_scope,
          'compra_em', ir.acquired_on, 'venda_em', ir.sold_on,
          'compra', ir.acquisition_cents, 'venda', ir.sale_cents, 'despesas', ir.expenses_cents,
          'hpp', ir.hpp_reinvestment, 'hpp_credito', ir.hpp_credit_cents, 'hpp_feito', ir.hpp_done
        ) order by ir.created_at), '[]'::jsonb)
        from public.income_records ir where ir.case_id = processo),
      'notas', (
        select coalesce(jsonb_object_agg(cn.tab, cn.body), '{}'::jsonb)
        from public.case_notes cn where cn.case_id = processo),
      'deducoes', (
        select to_jsonb(cd) - 'case_id' - 'account_id'
        from public.case_deductions cd where cd.case_id = processo),
      'documentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
          'imovel', d.property_id, 'rendimento', d.income_id, 'nome', d.file_name,
          'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at
        ) order by d.created_at desc), '[]'::jsonb)
        from public.documents d where d.case_id = processo)
    );
  end if;

  if vista = 'documentos' then
    return dados || jsonb_build_object(
      'documentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
          'nome', d.file_name, 'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at,
          'imovel', (select pa.label from public.property_assets pa where pa.id = d.property_id),
          'descargas', (
            select coalesce(jsonb_agg(dd.downloaded_at order by dd.downloaded_at desc), '[]'::jsonb)
            from public.document_downloads dd where dd.document_id = d.id)
        ) order by d.created_at desc), '[]'::jsonb)
        from public.documents d where d.case_id = processo)
    );
  end if;

  if vista = 'progresso' then
    return dados || jsonb_build_object(
      'processo', (
        select jsonb_build_object(
          'estado', c.status, 'desde', c.status_changed_at,
          'submetido_em', c.submitted_by_client_at,
          'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
        from public.irs_cases c where c.id = processo),
      'eventos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
        ) order by pe.created_at desc), '[]'::jsonb)
        from public.progress_events pe where pe.case_id = processo),
      -- O cliente vê quando é que a senha dele foi consultada, e de quem.
      'consultas_senha', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'pessoa', p.full_name, 'em', v.viewed_at
        ) order by v.viewed_at desc), '[]'::jsonb)
        from public.tax_credential_views v
        join public.people p on p.id = v.person_id
        where v.account_id = conta)
    );
  end if;

  if vista = 'mensagens' then
    return dados || jsonb_build_object(
      'mensagens', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', m.id, 'corpo', m.body, 'em', m.created_at, 'autor', m.author_id,
          'do_gabinete', exists(select 1 from public.staff_users s where s.user_id = m.author_id)
        ) order by m.created_at), '[]'::jsonb)
        from public.messages m where m.case_id = processo)
    );
  end if;

  if vista = 'pagamento' then
    return dados || jsonb_build_object(
      'processo', (
        select jsonb_build_object('estado', c.status, 'rotulo', c.label, 'ano', c.tax_year)
        from public.irs_cases c where c.id = processo),
      'checkout', (
        select jsonb_build_object(
          'id', k.id, 'estado', k.state, 'total', k.amount_cents,
          'desconto', k.discount_cents, 'detalhe', k.quote,
          'url', k.checkout_url, 'pago_em', k.paid_at)
        from public.irs_checkouts k
        where k.case_id = processo order by k.created_at desc limit 1)
    );
  end if;

  -- resumo
  return dados || jsonb_build_object(
    'membros', membros,
    'processo', (
      select jsonb_build_object('estado', c.status, 'desde', c.status_changed_at, 'ano', c.tax_year)
      from public.irs_cases c where c.id = processo),
    'contagens', jsonb_build_object(
      'rendimentos', (select count(*) from public.income_records where case_id = processo),
      'documentos', (select count(*) from public.documents where case_id = processo),
      'mensagens', (select count(*) from public.messages where case_id = processo))
  );
end $$;

-- Source: 202610260021_espaco_gabinete_consola.sql
-- A consola do contabilista não é o espelho do cliente.
-- O cliente navega um processo de cada vez; o contabilista precisa da fila
-- toda de uma vez e, quando abre um processo, de tudo junto no mesmo pedido.

create or replace function public.espaco_gabinete(vista text, processo uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  dados jsonb := jsonb_build_object('vista', vista, 'processo', processo);
begin
  if not public.is_staff() then
    return dados || jsonb_build_object('erro', 'sem_acesso');
  end if;

  if vista = 'fila' then
    return dados || jsonb_build_object(
      'processos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id, 'cliente', a.name, 'estado', c.status, 'desde', c.status_changed_at,
          'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
          'titulares', (select count(*) from public.case_people cp where cp.case_id = c.id),
          'rendimentos', (select count(*) from public.income_records ir where ir.case_id = c.id),
          'documentos', (select count(*) from public.documents d where d.case_id = c.id),
          'por_rever', (select count(*) from public.documents d
                         where d.case_id = c.id and d.state = 'uploaded'),
          'mensagens', (select count(*) from public.messages m where m.case_id = c.id),
          'dois_fatores', exists(select 1 from public.case_people cp
                                  join public.people p on p.id = cp.person_id
                                  where cp.case_id = c.id and p.tax_two_factor),
          'pago', exists(select 1 from public.irs_checkouts k
                          where k.case_id = c.id and k.state = 'paid')
        ) order by
          case c.status
            when 'submitted_by_client' then 0 when 'accepted' then 1
            when 'validation' then 2 when 'approved' then 3
            when 'submitting' then 4 when 'filed' then 5
            when 'monitoring' then 6 when 'collecting' then 7 else 8 end,
          c.status_changed_at), '[]'::jsonb)
        from public.irs_cases c
        join public.client_accounts a on a.id = c.account_id),
      'totais', jsonb_build_object(
        'abertos', (select count(*) from public.irs_cases where status <> 'closed'),
        'a_rever', (select count(*) from public.irs_cases
                     where status in ('submitted_by_client','accepted','validation')),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null))
    );
  end if;

  if vista = 'mensagens' then
    return dados || jsonb_build_object(
      'conversas', (
        select coalesce(jsonb_agg(x order by x->>'ultima' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
            'processo', c.id, 'cliente', a.name,
            'total', (select count(*) from public.messages m where m.case_id = c.id),
            'ultima', (select max(m.created_at) from public.messages m where m.case_id = c.id),
            'por_responder', exists(
              select 1 from public.messages m
              where m.case_id = c.id
                and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
                and m.created_at > coalesce((
                  select max(m2.created_at) from public.messages m2
                  join public.staff_users s2 on s2.user_id = m2.author_id
                  where m2.case_id = c.id), '-infinity'::timestamptz))
          ) as x
          from public.irs_cases c
          join public.client_accounts a on a.id = c.account_id
          where exists(select 1 from public.messages m where m.case_id = c.id)
        ) t)
    );
  end if;

  if vista = 'pagamentos' then
    return dados || jsonb_build_object(
      'pagamentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', k.id, 'processo', k.case_id, 'cliente', a.name,
          'estado', k.state, 'total', k.amount_cents, 'desconto', k.discount_cents,
          'criado', k.created_at, 'pago_em', k.paid_at
        ) order by k.created_at desc), '[]'::jsonb)
        from public.irs_checkouts k
        join public.client_accounts a on a.id = k.account_id)
    );
  end if;

  if vista = 'alertas' then
    return dados || jsonb_build_object(
      'alertas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', t.id, 'tipo', t.kind, 'em', t.created_at,
          'pessoa', p.full_name, 'cliente', a.name,
          'processo', (select c.id from public.irs_cases c
                        where c.account_id = t.account_id order by c.tax_year desc limit 1)
        ) order by t.created_at desc), '[]'::jsonb)
        from public.task_alerts t
        join public.client_accounts a on a.id = t.account_id
        left join public.people p on p.id = t.person_id
        where t.resolved_at is null)
    );
  end if;

  if processo is null then
    return dados || jsonb_build_object('erro', 'sem_processo');
  end if;

  return dados || jsonb_build_object(
    'cabecalho', (
      select jsonb_build_object(
        'cliente', a.name, 'conta', c.account_id,
        'estado', c.status, 'desde', c.status_changed_at,
        'ano', c.tax_year, 'submetido_em', c.submitted_by_client_at,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction,
        'nif', (select pr.nif from public.profiles pr
                 join public.account_access aa on aa.user_id = pr.id
                 where aa.account_id = c.account_id order by aa.role limit 1),
        'residencia', (select pr.tax_residence from public.profiles pr
                 join public.account_access aa on aa.user_id = pr.id
                 where aa.account_id = c.account_id order by aa.role limit 1))
      from public.irs_cases c
      join public.client_accounts a on a.id = c.account_id
      where c.id = processo),
    'membros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.full_name, 'nascimento', p.birth_date, 'nif', p.nif,
        'relacao', cp.relationship, 'dois_fatores', p.tax_two_factor,
        'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
        'consultas', (select count(*) from public.tax_credential_views v where v.person_id = p.id)
      ) order by case cp.relationship when 'titular' then 0 else 1 end, p.full_name), '[]'::jsonb)
      from public.case_people cp
      join public.people p on p.id = cp.person_id
      where cp.case_id = processo),
    'imoveis', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pa.id, 'nome', pa.label, 'tipo', pa.kind) order by pa.label), '[]'::jsonb)
      from public.property_assets pa where pa.case_id = processo),
    'rendimentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ir.id, 'categoria', ir.category, 'tipo', ir.kind, 'titulo', ir.title,
        'titular', ir.person_id, 'imovel', ir.property_id, 'valor', ir.amount_cents,
        'nota', ir.details, 'irs_jovem', ir.young_irs, 'estuda_trabalha', ir.studies_and_works,
        'ambito', ir.foreign_scope, 'compra_em', ir.acquired_on, 'venda_em', ir.sold_on,
        'compra', ir.acquisition_cents, 'venda', ir.sale_cents, 'despesas', ir.expenses_cents,
        'hpp', ir.hpp_reinvestment, 'hpp_credito', ir.hpp_credit_cents, 'hpp_feito', ir.hpp_done
      ) order by ir.category, ir.created_at), '[]'::jsonb)
      from public.income_records ir where ir.case_id = processo),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
        'nome', d.file_name, 'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at,
        'imovel', (select pa.label from public.property_assets pa where pa.id = d.property_id),
        'descargas', (select count(*) from public.document_downloads dd where dd.document_id = d.id)
      ) order by d.created_at desc), '[]'::jsonb)
      from public.documents d where d.case_id = processo),
    'notas', (
      select coalesce(jsonb_object_agg(cn.tab, cn.body), '{}'::jsonb)
      from public.case_notes cn where cn.case_id = processo),
    'deducoes', (
      select to_jsonb(cd) - 'case_id' - 'account_id'
      from public.case_deductions cd where cd.case_id = processo),
    'mensagens', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id, 'corpo', m.body, 'em', m.created_at,
        'do_gabinete', exists(select 1 from public.staff_users s where s.user_id = m.author_id)
      ) order by m.created_at), '[]'::jsonb)
      from public.messages m where m.case_id = processo),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo
      order by k.created_at desc limit 1)
  );
end $$;

-- Source: 202610260022_avancar_processo.sql
-- O avanço do processo pelo contabilista, com transições validadas.

-- Quem muda o estado não tem de se lembrar de carimbar a data. Um gatilho
-- faz isso sempre, venha a mudança de onde vier.
create or replace function public.carimbar_estado()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
    if new.status = 'submitted_by_client' and new.submitted_by_client_at is null then
      new.submitted_by_client_at := now();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists carimbar_estado on public.irs_cases;
create trigger carimbar_estado before update on public.irs_cases
for each row execute function public.carimbar_estado();

-- As transições possíveis a partir de cada estado. Fora desta tabela, não há.
create or replace function public.transicoes_do_estado(actual text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case actual
    when 'collecting'          then array['submitted_by_client']
    when 'submitted_by_client' then array['accepted','collecting']
    when 'accepted'            then array['validation','collecting']
    when 'validation'          then array['approved','collecting']
    when 'approved'            then array['submitting','validation']
    when 'submitting'          then array['filed','approved']
    when 'filed'               then array['monitoring']
    when 'monitoring'          then array['closed','filed']
    when 'closed'              then array['monitoring']
    else array[]::text[] end
$$;

/* O avanço do processo pelo contabilista.
   Valida a transição, carimba o valor apurado quando chega à submissão, e
   deixa sempre um evento para o cliente ver no acompanhamento. */
create or replace function public.avancar_processo(
  processo uuid,
  destino text,
  nota text default '',
  valor_cents bigint default null,
  sentido text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  rotulos jsonb := jsonb_build_object(
    'submitted_by_client','Processo submetido',
    'accepted','Processo aceite',
    'validation','Em validação',
    'approved','Aprovado',
    'submitting','Em processo de submissão',
    'filed','Submetido na Autoridade Tributária',
    'monitoring','Em acompanhamento',
    'closed','Processo fechado',
    'collecting','Devolvido para completar');
  -- O corpo do evento nunca pode ficar vazio: sem nota, explica-se o passo.
  corpos jsonb := jsonb_build_object(
    'submitted_by_client','O processo foi submetido e entrou na minha fila.',
    'accepted','Recebi o processo e abri-o para análise.',
    'validation','Estou a conferir os rendimentos e os documentos.',
    'approved','Está tudo conferido. O processo segue para submissão.',
    'submitting','A declaração está a ser entregue na Autoridade Tributária.',
    'filed','A declaração foi entregue.',
    'monitoring','À espera da validação da Autoridade Tributária.',
    'closed','O processo está concluído.',
    'collecting','Faltam elementos. A recolha foi reaberta.');
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;

  if not (destino = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, destino;
  end if;

  -- O valor apurado só faz sentido na entrega, e aí é obrigatório.
  if destino = 'filed' then
    if valor_cents is null or sentido is null then
      raise exception 'Indique o valor apurado e se e a reembolsar ou a pagar.';
    end if;
    if sentido not in ('refund','payment') or valor_cents < 0 then
      raise exception 'Valor apurado invalido.';
    end if;
    update public.irs_cases
       set status = destino, final_amount_cents = valor_cents, final_direction = sentido
     where id = processo;
  else
    update public.irs_cases set status = destino where id = processo;
  end if;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(),
            coalesce(rotulos->>destino, destino),
            coalesce(nullif(trim(nota), ''), corpos->>destino, destino));

  return destino;
end $$;

-- A mesma tabela passa a valer para a via antiga, que aceitava qualquer salto.
create or replace function public.publish_case_progress(
  account uuid, process uuid, event_title text, event_body text, new_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare actual text;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode='42501'; end if;
  select status into actual from public.irs_cases where id = process and account_id = account;
  if actual is null then raise exception 'Process not found'; end if;
  if new_status is distinct from actual
     and not (new_status = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, new_status;
  end if;
  update public.irs_cases set status = new_status where id = process and account_id = account;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (account, process, auth.uid(), event_title, event_body);
end $$;

-- Source: 202610260023_onboarding_residencia.sql
-- O onboarding passa a recolher a residência fiscal e, fora da UE, o
-- representante. A senha das Finanças não entra aqui: é cifrada pela
-- aplicação e escrita na tax_credentials, para nunca passar por esta função.

create or replace function public.guardar_residencia_fiscal(
  residencia text,
  rep_nome text default null,
  rep_contribuinte text default null,
  rep_email text default null,
  rep_telefone text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if residencia is null or residencia not in ('continente','acores','madeira','ue','fora_ue') then
    raise exception 'Indique a residencia fiscal.';
  end if;
  if residencia = 'fora_ue'
     and (nullif(trim(coalesce(rep_nome,'')),'') is null
          or nullif(trim(coalesce(rep_contribuinte,'')),'') is null
          or (nullif(trim(coalesce(rep_email,'')),'') is null
              and nullif(trim(coalesce(rep_telefone,'')),'') is null)) then
    raise exception 'Fora da UE e obrigatorio indicar o representante fiscal e um contacto.';
  end if;

  update public.profiles
     set tax_residence = residencia,
         rep_name = case when residencia = 'fora_ue' then nullif(trim(rep_nome),'') end,
         rep_nif = case when residencia = 'fora_ue' then nullif(trim(rep_contribuinte),'') end,
         rep_email = case when residencia = 'fora_ue' then nullif(trim(rep_email),'') end,
         rep_phone = case when residencia = 'fora_ue' then nullif(trim(rep_telefone),'') end
   where id = auth.uid();
end $$;

-- A pessoa do titular, para a aplicação saber onde guardar a senha.
create or replace function public.pessoa_titular(processo uuid)
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select cp.person_id from public.case_people cp
   where cp.case_id = processo and cp.relationship = 'titular' limit 1
$$;

-- Source: 202610260024_precos_campanhas_avisos.sql
-- Preços, campanhas e avisos deixam de viver em código.
-- A política semeia-se com os valores que já estavam na função, para o preço
-- não mudar no dia em que isto entra.

create table if not exists public.pricing_policies (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  activa boolean not null default false,
  valores jsonb not null,
  notas text not null default '',
  criada_em timestamptz not null default now(),
  criada_por uuid references auth.users(id)
);
alter table public.pricing_policies drop constraint if exists pricing_policies_nome_check;
alter table public.pricing_policies add constraint pricing_policies_nome_check
  check (length(nome) between 2 and 120);

-- Só uma política activa de cada vez: duas seria o preço a depender da sorte.
create unique index if not exists pricing_policies_uma_activa
  on public.pricing_policies ((activa)) where activa;

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  rotulo_publico text not null,
  tipo text not null,
  valor integer not null,
  activa boolean not null default false,
  inicio timestamptz,
  fim timestamptz,
  criada_em timestamptz not null default now(),
  criada_por uuid references auth.users(id)
);
alter table public.campaigns drop constraint if exists campaigns_tipo_check;
alter table public.campaigns add constraint campaigns_tipo_check
  check (tipo in ('percentagem','fixo'));
alter table public.campaigns drop constraint if exists campaigns_valor_check;
alter table public.campaigns add constraint campaigns_valor_check
  check (valor > 0 and (tipo <> 'percentagem' or valor <= 100));
alter table public.campaigns drop constraint if exists campaigns_janela_check;
alter table public.campaigns add constraint campaigns_janela_check
  check (inicio is null or fim is null or fim > inicio);
alter table public.campaigns drop constraint if exists campaigns_nomes_check;
alter table public.campaigns add constraint campaigns_nomes_check
  check (length(nome) between 2 and 120 and length(rotulo_publico) between 2 and 160);

create table if not exists public.avisos (
  id uuid primary key default gen_random_uuid(),
  mensagem text not null,
  tom text not null default 'info',
  activo boolean not null default false,
  inicio timestamptz,
  fim timestamptz,
  no_irs boolean not null default true,
  no_website boolean not null default false,
  criado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id)
);
alter table public.avisos drop constraint if exists avisos_mensagem_check;
alter table public.avisos add constraint avisos_mensagem_check
  check (length(mensagem) between 5 and 400);
alter table public.avisos drop constraint if exists avisos_tom_check;
alter table public.avisos add constraint avisos_tom_check
  check (tom in ('info','atencao','critico'));
alter table public.avisos drop constraint if exists avisos_janela_check;
alter table public.avisos add constraint avisos_janela_check
  check (inicio is null or fim is null or fim > inicio);

alter table public.pricing_policies enable row level security;
alter table public.campaigns enable row level security;
alter table public.avisos enable row level security;

drop policy if exists politica_gabinete on public.pricing_policies;
drop policy if exists campanha_gabinete on public.campaigns;
drop policy if exists aviso_gabinete on public.avisos;
drop policy if exists aviso_publico on public.avisos;

-- Preços e campanhas: só o gabinete mexe. O cliente vê o efeito no orçamento,
-- não a tabela.
create policy politica_gabinete on public.pricing_policies
  for all using (public.is_staff()) with check (public.is_staff());
create policy campanha_gabinete on public.campaigns
  for all using (public.is_staff()) with check (public.is_staff());
create policy aviso_gabinete on public.avisos
  for all using (public.is_staff()) with check (public.is_staff());

-- Os avisos activos são públicos: é esse o objectivo deles.
create policy aviso_publico on public.avisos
  for select using (
    activo
    and (inicio is null or inicio <= now())
    and (fim is null or fim > now())
  );

/* Os valores em vigor. Se não houver política activa, valem os que estavam
   na função — o preço nunca fica indefinido. */
create or replace function public.precos_em_vigor()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select valores from public.pricing_policies where activa limit 1),
    '{"base":1850,"varios_titulares":500,"a_e_b":1500,"b_adicional":500,
      "rendas_unica":0,"rendas_ate2":500,"rendas_ate5":1000,"rendas_mais":2000,
      "mais_valias_titulos":1000,"mais_valias_imovel":1000}'::jsonb)
$$;

/** A campanha em vigor, se houver. */
create or replace function public.campanha_em_vigor()
returns public.campaigns
language sql
stable
set search_path = ''
as $$
  select * from public.campaigns
   where activa
     and (inicio is null or inicio <= now())
     and (fim is null or fim > now())
   order by criada_em desc limit 1
$$;

-- Source: 202610260025_precos_configuraveis.sql
-- O preço passa a sair da política em vigor em vez de números no corpo da
-- função. Os valores por omissão são os que lá estavam, por isso nada muda
-- enquanto não for criada uma política.

create or replace function public.price_irs_case(account uuid, process uuid)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  p jsonb := public.precos_em_vigor();
  items jsonb;
  total integer;
  workers integer; sales integer; rents integer;
  has_a boolean; has_b boolean; has_h boolean; has_g boolean;
  kinds integer; amount integer;
  v integer;
begin
  if not public.can_read_account(account)
     or not exists(select 1 from public.irs_cases c where c.id = process and c.account_id = account) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  v := (p->>'base')::int;
  items := jsonb_build_array(jsonb_build_object(
    'code','base',
    'label','Preparação IRS — primeiro tipo de rendimento (IVA incluído)',
    'amount_cents', v));
  total := v;

  select count(distinct person_id) filter (where category in ('employment','pension')),
         count(distinct property_id) filter (where category = 'property_sale'),
         count(distinct property_id) filter (where category = 'property_rent'),
         coalesce(bool_or(category = 'employment'), false),
         coalesce(bool_or(category = 'independent'), false),
         coalesce(bool_or(category = 'pension'), false),
         coalesce(bool_or(category = 'securities'), false),
         count(distinct category) filter (where category <> 'deduction')
    into workers, sales, rents, has_a, has_b, has_h, has_g, kinds
    from public.income_records where account_id = account and case_id = process;

  if kinds = 0 then
    raise exception 'Add at least one income type' using errcode = '22023';
  end if;

  if workers > 1 then
    v := (p->>'varios_titulares')::int;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','household_work','label','Várias pessoas com trabalho ou pensões','amount_cents', v));
    total := total + v;
  end if;

  if has_a and has_b then
    v := (p->>'a_e_b')::int;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','a_and_b','label','Acumulação de categorias A e B','amount_cents', v));
    total := total + v;
  elsif has_h and has_b then
    v := (p->>'b_adicional')::int;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','additional_b','label','Categoria B adicional às pensões','amount_cents', v));
    total := total + v;
  end if;

  if rents > 0 then
    amount := case
      when rents <= 2 then case when kinds = 1 then (p->>'rendas_unica')::int else (p->>'rendas_ate2')::int end
      when rents <= 5 then (p->>'rendas_ate5')::int
      else (p->>'rendas_mais')::int end;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','rents','label','Rendas — ' || rents || ' imóvel(is)','amount_cents', amount));
    total := total + amount;
  end if;

  if has_g then
    amount := (p->>'mais_valias_titulos')::int;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','securities','label','Mais-valias de ações e outros títulos — categoria G','amount_cents', amount));
    total := total + amount;
  end if;

  if sales > 0 then
    amount := (p->>'mais_valias_imovel')::int * sales;
    items := items || jsonb_build_array(jsonb_build_object(
      'code','property_sales','label','Mais-valias de imóveis — ' || sales || ' imóvel(is)','amount_cents', amount));
    total := total + amount;
  end if;

  return jsonb_build_object(
    'version','2026-10-26.1','currency','EUR','items', items,
    'subtotal_cents', total, 'vat_included', true);
end $$;

-- Source: 202610260026_campanha_no_orcamento.sql
-- A campanha em vigor entra no orçamento.
-- Não acumula com o código de desconto: aplica-se o maior dos dois. Acumular
-- dá descontos que ninguém tencionou, e é mais fácil de explicar assim.

create or replace function public.quote_irs_checkout(account uuid, process uuid, coupon text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  quote jsonb;
  discount public.discount_codes;
  campanha public.campaigns;
  reduction integer := 0;
  pela_campanha integer := 0;
  total integer;
  used integer;
  billing public.profiles;
  rotulo text;
begin
  quote := public.price_irs_case(account, process);
  total := (quote->>'subtotal_cents')::integer;

  select p.* into strict billing
    from public.profiles p
    join public.account_access a on a.user_id = p.id
   where a.account_id = account and a.role = 'owner';

  if billing.irs_free then
    return quote || jsonb_build_object(
      'discount_id', null, 'discount_code', 'CLIENTE GRATUITO',
      'discount_cents', total, 'total_cents', 0);
  end if;

  if billing.forced_discount_id is not null then
    select code into coupon from public.discount_codes where id = billing.forced_discount_id;
    if coupon is null then raise exception 'Required discount unavailable'; end if;
  end if;

  if btrim(coalesce(coupon, '')) <> '' then
    select * into discount from public.discount_codes where code = upper(btrim(coupon));
    if not found then raise exception 'Discount unavailable' using errcode = '22023'; end if;
    select count(*) into used from public.irs_checkouts
      where discount_id = discount.id and state in ('creating','pending','unknown','paid');
    if not discount.active
       or (discount.allowed_user is not null and discount.allowed_user <> billing.id)
       or (discount.starts_at is not null and discount.starts_at > now())
       or (discount.ends_at is not null and discount.ends_at <= now())
       or (discount.max_uses is not null and used >= discount.max_uses) then
      raise exception 'Discount unavailable' using errcode = '22023';
    end if;
    reduction := least(total, case when discount.kind = 'fixed' then discount.value
                                   else ((total::bigint * discount.value + 5000) / 10000)::integer end);
    rotulo := discount.code;
  end if;

  campanha := public.campanha_em_vigor();
  if campanha.id is not null then
    pela_campanha := least(total, case when campanha.tipo = 'fixo' then campanha.valor
                                       else ((total::bigint * campanha.valor + 50) / 100)::integer end);
    if pela_campanha > reduction then
      reduction := pela_campanha;
      rotulo := campanha.rotulo_publico;
      discount := null;
    end if;
  end if;

  return quote || jsonb_build_object(
    'discount_id', discount.id,
    'discount_code', rotulo,
    'discount_cents', reduction,
    'total_cents', total - reduction,
    'campanha', case when campanha.id is not null
                     then jsonb_build_object('rotulo', campanha.rotulo_publico) end);
end $$;

-- Source: 202610260027_email_ja_registado.sql
-- O Supabase não diz se um email já existe — protege contra enumeração de
-- contas. O efeito colateral é que o registo repetido parece correr bem e o
-- email de confirmação nunca chega.
--
-- Esta função diz apenas se o endereço já tem conta. Não devolve o
-- utilizador nem o estado dele. Só a chave de serviço lhe chega: sem GRANT
-- para anon ou authenticated, ninguém a pode usar para varrer endereços.

create or replace function public.email_ja_registado(endereco text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from auth.users
     where lower(email) = lower(btrim(endereco))
       and deleted_at is null
  )
$$;

revoke all on function public.email_ja_registado(text) from public, anon, authenticated;

-- Source: 202610260028_conflito_de_nif.sql
-- Deteta se um NIF já está em uso e diz de que tipo é o conflito, para o
-- onboarding poder explicar em vez de falhar com uma violação de unicidade.
--
-- Não devolve nomes nem emails de terceiros: só o tipo de conflito e se a
-- conta do outro lado já tem histórico a sério. Quem escreve um NIF que não
-- é seu não fica a saber de quem ele é.

create or replace function public.conflito_de_nif(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  minha_conta uuid;
  dono uuid;
  pessoa record;
  com_historico boolean;
begin
  if eu is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if contribuinte !~ '^[0-9]{9}$' then
    return jsonb_build_object('tipo', 'invalido');
  end if;

  select account_id into minha_conta
    from public.account_access where user_id = eu order by role limit 1;

  select id into dono from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;

  if dono is not null then
    select exists(
      select 1 from public.irs_cases c
       join public.account_access a on a.account_id = c.account_id
       where a.user_id = dono
         and (c.status <> 'collecting'
              or exists(select 1 from public.irs_checkouts k
                         where k.case_id = c.id and k.state = 'paid'))
    ) into com_historico;
    return jsonb_build_object('tipo', 'conta', 'com_historico', coalesce(com_historico, false));
  end if;

  select p.id, cp.relationship, cp.case_id, p.account_id
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte
     and (minha_conta is null or p.account_id <> minha_conta)
   limit 1;

  if pessoa.id is not null then
    select exists(
      select 1 from public.irs_cases c
       where c.id = pessoa.case_id
         and (c.status <> 'collecting'
              or exists(select 1 from public.irs_checkouts k
                         where k.case_id = c.id and k.state = 'paid'))
    ) into com_historico;
    return jsonb_build_object(
      'tipo', case when pessoa.relationship = 'titular' then 'conta' else 'agregado' end,
      'relacao', pessoa.relationship,
      'com_historico', coalesce(com_historico, false));
  end if;

  return jsonb_build_object('tipo', 'nenhum');
end $$;

-- O alerta que fica para o gabinete quando há conflito.
create or replace function public.alertar_conflito_de_nif(contribuinte text, tipo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select account_id into conta from public.account_access
   where user_id = auth.uid() order by role limit 1;
  if conta is null then return; end if;

  -- Um alerta por conta e por tipo: repetir a tentativa não enche a fila.
  if exists(select 1 from public.task_alerts
             where account_id = conta and kind = 'nif_' || tipo and resolved_at is null) then
    return;
  end if;
  insert into public.task_alerts(account_id, kind) values (conta, 'nif_' || tipo);
end $$;

-- Source: 202610260029_resolver_conflito_de_nif.sql
-- As duas saídas para um conflito de NIF, pedidas pelo próprio utilizador.
--
-- Mexem em dados de outra conta, por isso: exigem uma palavra de confirmação,
-- recusam-se quando a outra conta já tem histórico a sério (processo
-- submetido ou pagamento), e deixam sempre rasto em management_audit.

create or replace function public.apagar_conta_do_nif(contribuinte text, confirmacao text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  alvo uuid;
  conta uuid;
  apagados jsonb;
  ficheiros text[];
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'APAGAR' then raise exception 'Falta a confirmacao.'; end if;
  if contribuinte !~ '^[0-9]{9}$' then raise exception 'NIF invalido.'; end if;

  select id into alvo from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;
  if alvo is null then raise exception 'Nao ha conta anterior com este NIF.'; end if;

  select a.account_id into conta from public.account_access a
   where a.user_id = alvo order by a.role limit 1;
  if conta is null then raise exception 'Conta anterior nao encontrada.'; end if;

  -- Travão: histórico a sério não se apaga sozinho.
  if exists(
    select 1 from public.irs_cases c
     where c.account_id = conta
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'A conta anterior tem um processo submetido ou pago. O contabilista tem de a tratar.';
  end if;

  select coalesce(array_agg(d.storage_path), array[]::text[]) into ficheiros
    from public.documents d where d.account_id = conta;

  apagados := jsonb_build_object(
    'rendimentos', (select count(*) from public.income_records where account_id = conta),
    'documentos', (select count(*) from public.documents where account_id = conta),
    'pessoas', (select count(*) from public.people where account_id = conta),
    'processos', (select count(*) from public.irs_cases where account_id = conta));

  delete from public.document_downloads where account_id = conta;
  delete from public.documents where account_id = conta;
  delete from public.income_records where account_id = conta;
  delete from public.case_notes where account_id = conta;
  delete from public.case_deductions where account_id = conta;
  delete from public.property_assets where account_id = conta;
  delete from public.messages where account_id = conta;
  delete from public.progress_events where account_id = conta;
  delete from public.irs_checkouts where account_id = conta;
  delete from public.task_alerts where account_id = conta;
  delete from public.household_invitations where account_id = conta;
  delete from public.invitation_requests where account_id = conta;
  delete from public.tax_credential_views where account_id = conta;
  delete from public.tax_credentials where account_id = conta;
  delete from public.case_people where account_id = conta;
  delete from public.people where account_id = conta;
  delete from public.irs_cases where account_id = conta;
  delete from public.account_access where account_id = conta;
  delete from public.client_accounts where id = conta;

  -- O utilizador em si fica marcado como eliminado: apagar a conta Auth
  -- pertence à administração, não a esta função.
  update public.profiles set deleted_at = now(), nif = null where id = alvo;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, alvo, 'nif_conta_apagada');

  return jsonb_build_object('apagados', apagados, 'ficheiros', to_jsonb(ficheiros));
end $$;

/* A migração sai de um agregado alheio para conta própria.
   Primeiro passo: diz o que há para mover, sem mover nada. */
create or replace function public.preparar_migracao_do_agregado(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'O processo do outro agregado ja foi submetido ou pago. O contabilista tem de o tratar.';
  end if;

  return jsonb_build_object(
    'pessoa', pessoa.id,
    'processo_antigo', pessoa.case_id,
    'relacao', pessoa.relationship,
    'rendimentos', (select count(*) from public.income_records
                     where case_id = pessoa.case_id and person_id = pessoa.id),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'caminho', d.storage_path, 'nome', d.file_name, 'tipo', d.kind,
        'categoria', d.category, 'descricao', d.description, 'mime', d.mime_type,
        'tamanho', d.file_size, 'hash', d.content_hash, 'rendimento', d.income_id)), '[]'::jsonb)
      from public.documents d
      join public.income_records ir on ir.id = d.income_id
      where ir.case_id = pessoa.case_id and ir.person_id = pessoa.id));
end $$;

/* Segundo passo: já com os ficheiros copiados para os caminhos novos, move
   as linhas numa transação só.
   A senha das Finanças não migra, de propósito: a pessoa volta a escrevê-la
   na conta nova. Uma credencial que muda de dono sem passar pelo dono deixa
   de ser uma credencial. */
create or replace function public.concluir_migracao_do_agregado(
  contribuinte text,
  confirmacao text,
  documentos jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
  minha_conta uuid;
  meu_processo uuid;
  meu_titular uuid;
  doc jsonb;
  movidos int := 0;
  rendimentos int := 0;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'MIGRAR' then raise exception 'Falta a confirmacao.'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'O processo do outro agregado ja foi submetido ou pago.';
  end if;

  select a.account_id into minha_conta from public.account_access a
   where a.user_id = eu order by a.role limit 1;
  if minha_conta is null then raise exception 'Complete primeiro o seu registo.'; end if;

  select id into meu_processo from public.irs_cases
   where account_id = minha_conta order by tax_year desc limit 1;
  if meu_processo is null then raise exception 'Nao tem processo aberto.'; end if;

  select cp.person_id into meu_titular from public.case_people cp
   where cp.case_id = meu_processo and cp.relationship = 'titular';
  if meu_titular is null then raise exception 'Falta o titular no seu processo.'; end if;

  update public.income_records
     set account_id = minha_conta, case_id = meu_processo, person_id = meu_titular
   where case_id = pessoa.case_id and person_id = pessoa.id;
  get diagnostics rendimentos = row_count;

  -- Os documentos são recriados no caminho novo: o caminho antigo tem a
  -- conta e o processo antigos lá dentro, e há uma restrição que o exige.
  for doc in select * from jsonb_array_elements(documentos) loop
    insert into public.documents(
      id, account_id, case_id, income_id, kind, file_name, storage_path,
      mime_type, file_size, state, uploaded_by, content_hash, category, description)
    values (
      (doc->>'novo_id')::uuid, minha_conta, meu_processo,
      (doc->>'rendimento')::uuid, doc->>'tipo', doc->>'nome', doc->>'novo_caminho',
      doc->>'mime', (doc->>'tamanho')::bigint, 'uploaded', eu,
      doc->>'hash', doc->>'categoria', doc->>'descricao');
    delete from public.documents where id = (doc->>'id')::uuid;
    movidos := movidos + 1;
  end loop;

  delete from public.tax_credential_views where person_id = pessoa.id;
  delete from public.tax_credentials where person_id = pessoa.id;
  delete from public.case_people where case_id = pessoa.case_id and person_id = pessoa.id;
  delete from public.people where id = pessoa.id;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, pessoa.id, 'nif_migrado_do_agregado');

  return jsonb_build_object('rendimentos', rendimentos, 'documentos', movidos);
end $$;

-- Source: 202610260030_alerta_quando_o_travao_dispara.sql
-- Quando o travão impede o self-service, o caso passa a ser do gabinete.
--
-- Duas correções a defeitos reais encontrados a testar isto:
--
-- 1. O alerta não pode ser escrito dentro da função que recusa: o raise
--    desfaz a transação e leva o insert com ele. As funções passam a recusar
--    com um código próprio (P0003) e quem chama regista o alerta já fora da
--    transação abortada.
--
-- 2. task_alerts.person_id era obrigatório, e um conflito de NIF é detetado
--    antes de existir a ficha da pessoa. Os inserts falhavam — e falhavam em
--    silêncio, porque quem os chamava não olhava para o erro.

alter table public.task_alerts alter column person_id drop not null;

create or replace function public.marcar_conflito_para_o_gabinete(motivo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  select account_id into conta from public.account_access
   where user_id = auth.uid() order by role limit 1;
  if conta is null then return; end if;
  -- Um alerta por conta: repetir a tentativa não enche a fila.
  if exists(select 1 from public.task_alerts
             where account_id = conta and kind = 'nif_bloqueado' and resolved_at is null) then
    return;
  end if;
  insert into public.task_alerts(account_id, kind) values (conta, 'nif_bloqueado');
end $$;

create or replace function public.apagar_conta_do_nif(contribuinte text, confirmacao text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  alvo uuid;
  conta uuid;
  apagados jsonb;
  ficheiros text[];
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'APAGAR' then raise exception 'Falta a confirmacao.'; end if;
  if contribuinte !~ '^[0-9]{9}$' then raise exception 'NIF invalido.'; end if;

  select id into alvo from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;
  if alvo is null then raise exception 'Nao ha conta anterior com este NIF.'; end if;

  select a.account_id into conta from public.account_access a
   where a.user_id = alvo order by a.role limit 1;
  if conta is null then raise exception 'Conta anterior nao encontrada.'; end if;

  -- Travão: histórico a sério não se apaga sozinho.
  if exists(
    select 1 from public.irs_cases c
     where c.account_id = conta
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'Conta anterior com processo submetido ou pago.' using errcode = 'P0003';
  end if;

  select coalesce(array_agg(d.storage_path), array[]::text[]) into ficheiros
    from public.documents d where d.account_id = conta;

  apagados := jsonb_build_object(
    'rendimentos', (select count(*) from public.income_records where account_id = conta),
    'documentos', (select count(*) from public.documents where account_id = conta),
    'pessoas', (select count(*) from public.people where account_id = conta),
    'processos', (select count(*) from public.irs_cases where account_id = conta));

  delete from public.document_downloads where account_id = conta;
  delete from public.documents where account_id = conta;
  delete from public.income_records where account_id = conta;
  delete from public.case_notes where account_id = conta;
  delete from public.case_deductions where account_id = conta;
  delete from public.property_assets where account_id = conta;
  delete from public.messages where account_id = conta;
  delete from public.progress_events where account_id = conta;
  delete from public.irs_checkouts where account_id = conta;
  delete from public.task_alerts where account_id = conta;
  delete from public.household_invitations where account_id = conta;
  delete from public.invitation_requests where account_id = conta;
  delete from public.tax_credential_views where account_id = conta;
  delete from public.tax_credentials where account_id = conta;
  delete from public.case_people where account_id = conta;
  delete from public.people where account_id = conta;
  delete from public.irs_cases where account_id = conta;
  delete from public.account_access where account_id = conta;
  delete from public.client_accounts where id = conta;

  -- O utilizador em si fica marcado como eliminado: apagar a conta Auth
  -- pertence à administração, não a esta função.
  update public.profiles set deleted_at = now(), nif = null where id = alvo;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, alvo, 'nif_conta_apagada');

  return jsonb_build_object('apagados', apagados, 'ficheiros', to_jsonb(ficheiros));
end $$;

/* A migração sai de um agregado alheio para conta própria.
   Primeiro passo: diz o que há para mover, sem mover nada. */
create or replace function public.preparar_migracao_do_agregado(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'Agregado com processo submetido ou pago.' using errcode = 'P0003';
  end if;

  return jsonb_build_object(
    'pessoa', pessoa.id,
    'processo_antigo', pessoa.case_id,
    'relacao', pessoa.relationship,
    'rendimentos', (select count(*) from public.income_records
                     where case_id = pessoa.case_id and person_id = pessoa.id),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'caminho', d.storage_path, 'nome', d.file_name, 'tipo', d.kind,
        'categoria', d.category, 'descricao', d.description, 'mime', d.mime_type,
        'tamanho', d.file_size, 'hash', d.content_hash, 'rendimento', d.income_id)), '[]'::jsonb)
      from public.documents d
      join public.income_records ir on ir.id = d.income_id
      where ir.case_id = pessoa.case_id and ir.person_id = pessoa.id));
end $$;

-- Source: 202610260031_agregado_e_senhas.sql
-- Três defeitos no mesmo sítio, todos encontrados a testar:
--
-- 1. O parâmetro chamava-se nif, como a coluna. "nif = nif" num UPDATE é
--    ambíguo e o Postgres recusa: editar um membro — incluindo ligar o 2FA —
--    falhava sempre.
--
-- 2. A função corria com as permissões de quem chama, e o papel authenticated
--    não tem UPDATE em people nem INSERT em tax_credentials. Passam a
--    security definer, com a autorização verificada à mão.
--
-- 3. birth_date é obrigatório na tabela e é dele que depende o IRS Jovem,
--    mas nada o exigia: rebentava numa violação de not-null sem explicação.

drop function if exists public.guardar_membro_agregado(uuid, text, text, text, uuid, date, boolean);

create or replace function public.guardar_membro_agregado(
  processo uuid,
  p_nome text,
  p_nif text,
  p_relacao text,
  p_pessoa uuid default null,
  p_nascimento date default null,
  p_dois_fatores boolean default false
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  destino uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_edit_case(conta, processo) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_nome is null or length(btrim(p_nome)) < 2 then
    raise exception 'Indique o nome completo.';
  end if;
  if p_nif !~ '^[0-9]{9}$' then
    raise exception 'O NIF tem nove digitos.';
  end if;
  if p_nascimento is null then
    raise exception 'Indique a data de nascimento: e dela que depende o IRS Jovem.';
  end if;
  if p_nascimento > current_date then
    raise exception 'A data de nascimento nao pode ser no futuro.';
  end if;
  if p_relacao not in ('titular','conjuge','descendente','ascendente','outro') then
    raise exception 'Relacao invalida.';
  end if;

  if p_pessoa is null then
    insert into public.people(account_id, full_name, birth_date, nif, tax_two_factor)
      values (conta, btrim(p_nome), p_nascimento, p_nif, p_dois_fatores)
      returning id into destino;
  else
    update public.people
       set full_name = btrim(p_nome),
           birth_date = p_nascimento,
           nif = p_nif,
           tax_two_factor = p_dois_fatores
     where id = p_pessoa and account_id = conta
     returning id into destino;
    if destino is null then
      raise exception 'Membro nao encontrado nesta conta.';
    end if;
  end if;

  insert into public.case_people(account_id, case_id, person_id, relationship)
    values (conta, processo, destino, p_relacao)
    on conflict (case_id, person_id) do update set relationship = excluded.relationship;

  return destino;
end $$;

create or replace function public.guardar_senha_financas(
  processo uuid,
  p_pessoa uuid,
  p_cifrada text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_read_account(conta) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists(select 1 from public.case_people
                 where case_id = processo and person_id = p_pessoa) then
    raise exception 'Membro nao pertence a este processo.';
  end if;

  insert into public.tax_credentials(person_id, account_id, encrypted_password, updated_at, updated_by)
    values (p_pessoa, conta, p_cifrada, now(), auth.uid())
  on conflict (person_id) do update
    set encrypted_password = excluded.encrypted_password,
        updated_at = now(),
        updated_by = excluded.updated_by;
end $$;

-- Source: 202610260032_pagamento_stripe.sql
-- Liquidação de um pagamento Stripe.
-- Mantém as garantias da via anterior: só avança se o identificador, a
-- referência, o montante e a moeda baterem certo; é idempotente; e só sai
-- dos estados pending/unknown.

create or replace function public.anexar_sessao_de_pagamento(
  attempt uuid, provider_id text, provider_url text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.irs_checkouts
     set provider_order_id = provider_id, checkout_url = provider_url, state = 'pending'
   where id = attempt and state in ('creating','pending','unknown');
  if not found then raise exception 'Payment attempt not open'; end if;
end $$;

create or replace function public.finalizar_pagamento_stripe(
  attempt uuid,
  provider_id text,
  provider_reference text,
  pago boolean,
  falhou boolean,
  provider_amount integer,
  provider_currency text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare payment public.irs_checkouts;
begin
  select * into strict payment from public.irs_checkouts where id = attempt for update;

  if payment.provider_order_id is distinct from provider_id
     or payment.id::text is distinct from provider_reference
     or payment.amount_cents is distinct from provider_amount
     or lower(provider_currency) is distinct from 'eur' then
    raise exception 'Order mismatch';
  end if;

  if payment.state = 'paid' then return; end if;
  if payment.state not in ('pending','unknown') then raise exception 'Invalid payment state'; end if;

  update public.irs_checkouts set last_checked_at = now() where id = attempt;

  if pago then
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client'
     where id = payment.case_id and status in ('collecting');
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              'Pagamento confirmado',
              'Processo recebido para revisão pelo contabilista. A declaração ainda não foi submetida à AT.');
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;

-- Source: 202610270033_fluxo_do_processo.sql
-- O fluxo do processo tinha nove estados em linha e dois buracos: um processo
-- devolvido ficava igual a um que nunca começou, e o cliente não tinha forma
-- de submeter o seu próprio processo — só eu o podia marcar como submetido.
--
-- Esta migração: (1) acrescenta "returned", "assessed" e "divergence", que são
-- níveis reais do processo; (2) dá ao cliente a ação de submeter, com
-- pré-requisitos verificados no servidor; (3) põe num sítio só a lista de
-- prontidão que as duas óticas mostram.

-- 1. Os estados novos.
alter table public.irs_cases drop constraint irs_cases_status_check;
alter table public.irs_cases add constraint irs_cases_status_check
  check (status = any (array[
    'collecting','returned','submitted_by_client','accepted','validation',
    'approved','submitting','filed','monitoring','divergence','assessed','closed']));

-- 2. O grafo. "returned" é o caminho de volta: substitui o antigo
--    "devolver para collecting", que apagava o facto de ter sido devolvido.
create or replace function public.transicoes_do_estado(actual text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case actual
    when 'collecting'          then array['submitted_by_client']
    when 'returned'            then array['submitted_by_client','accepted']
    when 'submitted_by_client' then array['accepted','returned']
    when 'accepted'            then array['validation','returned']
    when 'validation'          then array['approved','returned']
    when 'approved'            then array['submitting','validation']
    when 'submitting'          then array['filed','approved']
    when 'filed'               then array['monitoring']
    when 'monitoring'          then array['assessed','divergence','closed','filed']
    when 'divergence'          then array['assessed','monitoring']
    when 'assessed'            then array['closed','divergence']
    when 'closed'              then array['assessed','monitoring']
    else array[]::text[] end
$$;

-- 3. Os rótulos e os corpos dos eventos, com os estados novos. O resto da
--    função é o que já lá estava.
create or replace function public.avancar_processo(
  processo uuid, destino text, nota text default '',
  valor_cents bigint default null, sentido text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  rotulos jsonb := jsonb_build_object(
    'submitted_by_client','Processo submetido',
    'accepted','Processo aceite',
    'validation','Em validação',
    'approved','Aprovado',
    'submitting','Em processo de submissão',
    'filed','Submetido na Autoridade Tributária',
    'monitoring','Em acompanhamento',
    'divergence','Em divergência',
    'assessed','Liquidação emitida',
    'closed','Processo fechado',
    'returned','Devolvido para completar',
    'collecting','Recolha reaberta');
  -- O corpo do evento nunca pode ficar vazio: sem nota, explica-se o passo.
  corpos jsonb := jsonb_build_object(
    'submitted_by_client','O processo foi submetido e entrou na minha fila.',
    'accepted','Recebi o processo e abri-o para análise.',
    'validation','Estou a conferir os rendimentos e os documentos.',
    'approved','Está tudo conferido. O processo segue para submissão.',
    'submitting','A declaração está a ser entregue na Autoridade Tributária.',
    'filed','A declaração foi entregue.',
    'monitoring','À espera da validação da Autoridade Tributária.',
    'divergence','A Autoridade Tributária levantou uma divergência. Vou tratar dela e aviso-o do que for preciso.',
    'assessed','A liquidação foi emitida. O valor apurado está confirmado.',
    'closed','O processo está concluído.',
    'returned','Faltam elementos. Pode completar o processo e submeter outra vez.',
    'collecting','A recolha foi reaberta.');
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;

  if not (destino = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, destino;
  end if;

  if destino = 'filed' then
    if valor_cents is null or sentido is null then
      raise exception 'Indique o valor apurado e se e a reembolsar ou a pagar.';
    end if;
    if sentido not in ('refund','payment') or valor_cents < 0 then
      raise exception 'Valor apurado invalido.';
    end if;
    update public.irs_cases
       set status = destino, final_amount_cents = valor_cents, final_direction = sentido
     where id = processo;
  else
    update public.irs_cases set status = destino where id = processo;
  end if;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(),
            coalesce(rotulos->>destino, destino),
            coalesce(nullif(trim(nota), ''), corpos->>destino, destino));

  return destino;
end $$;

-- 4. A prontidão do processo. É a mesma lista nas duas óticas: o cliente vê o
--    que falta da parte dele, eu vejo tudo antes de aprovar. "bloqueia" marca
--    o que impede a submissão pelo cliente; o pagamento e o 2FA não impedem,
--    avisam.
create or replace function public.prontidao_do_processo(processo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conta uuid;
  titular public.people;
  com_senha boolean;
  com_2fa int;
  rendimentos int;
  documentos int;
  pago text;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then return '[]'::jsonb; end if;
  if not (public.is_staff() or public.can_edit_case(conta, processo)) then
    return '[]'::jsonb;
  end if;

  select p.* into titular
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and cp.relationship = 'titular' limit 1;

  select exists(select 1 from public.tax_credentials tc where tc.person_id = titular.id)
    into com_senha;

  select count(*) into com_2fa
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and p.tax_two_factor;

  select count(*) into rendimentos from public.income_records where case_id = processo;
  select count(*) into documentos from public.documents where case_id = processo;

  select k.state into pago from public.irs_checkouts k
   where k.case_id = processo order by k.created_at desc limit 1;

  return jsonb_build_array(
    jsonb_build_object(
      'chave','titular', 'de','cliente', 'bloqueia', true,
      'rotulo','Dados do titular',
      'estado', case when titular.nif is not null and titular.birth_date is not null
                     then 'ok' else 'falta' end,
      'detalhe', case when titular.nif is null then 'Falta o NIF.'
                      when titular.birth_date is null then 'Falta a data de nascimento.'
                      else coalesce(titular.full_name,'') end),
    jsonb_build_object(
      'chave','senha', 'de','cliente', 'bloqueia', true,
      'rotulo','Senha das Finanças do titular',
      'estado', case when com_senha then 'ok' else 'falta' end,
      'detalhe', case when com_senha then 'Guardada e cifrada.'
                      else 'Sem a senha não consigo entrar no Portal das Finanças.' end),
    jsonb_build_object(
      'chave','rendimentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Rendimentos declarados',
      'estado', case when rendimentos > 0 then 'ok' else 'falta' end,
      'detalhe', case when rendimentos > 0 then rendimentos || ' linha(s).'
                      else 'Declare pelo menos uma categoria de rendimento.' end),
    jsonb_build_object(
      'chave','documentos', 'de','cliente', 'bloqueia', false,
      'rotulo','Documentos enviados',
      'estado', case when documentos > 0 then 'ok' else 'atencao' end,
      'detalhe', case when documentos > 0 then documentos || ' ficheiro(s).'
                      else 'Ainda não enviou documentos. Pode submeter sem eles, mas posso pedir-lhos.' end),
    jsonb_build_object(
      'chave','dois_fatores', 'de','gabinete', 'bloqueia', false,
      'rotulo','Autenticação de dois fatores',
      'estado', case when com_2fa > 0 then 'atencao' else 'ok' end,
      'detalhe', case when com_2fa > 0
                      then com_2fa || ' pessoa(s) com 2FA: é preciso contacto na hora da submissão.'
                      else 'Ninguém do agregado tem 2FA ativo.' end),
    jsonb_build_object(
      'chave','pagamento', 'de','cliente', 'bloqueia', false,
      'rotulo','Pagamento da preparação',
      'estado', case pago when 'paid' then 'ok' when 'pending' then 'atencao' else 'falta' end,
      'detalhe', case pago
                   when 'paid' then 'Recebido.'
                   when 'pending' then 'A aguardar liquidação — o Multibanco pode levar horas.'
                   when 'failed' then 'A última tentativa falhou.'
                   else 'Ainda não foi pago.' end)
  );
end $$;

grant execute on function public.prontidao_do_processo(uuid) to authenticated;

-- 5. O cliente submete o seu processo. Era o primeiro passo do percurso e não
--    existia: só o gabinete conseguia marcar o processo como submetido.
create or replace function public.submeter_processo(processo uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  lista jsonb;
  faltas text[];
begin
  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;
  if not (public.can_edit_case(conta, processo) or public.is_staff()) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if actual not in ('collecting','returned') then
    raise exception 'O processo já foi submetido.' using errcode = 'P0004';
  end if;

  lista := public.prontidao_do_processo(processo);
  select array_agg(x->>'rotulo') into faltas
    from jsonb_array_elements(lista) x
   where (x->>'bloqueia')::boolean and x->>'estado' = 'falta';

  if faltas is not null then
    return jsonb_build_object('ok', false, 'faltas', to_jsonb(faltas), 'prontidao', lista);
  end if;

  update public.irs_cases
     set status = 'submitted_by_client',
         submitted_by_client_at = coalesce(submitted_by_client_at, now())
   where id = processo;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(), 'Processo submetido',
            'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.');

  return jsonb_build_object('ok', true, 'estado', 'submitted_by_client');
end $$;

grant execute on function public.submeter_processo(uuid) to authenticated;

-- 6. A vista do acompanhamento. O espaco_irs('progresso') devolvia o estado,
--    os eventos e as consultas à senha — e nada sobre o que falta ou sobre o
--    pagamento, que é justamente o que o cliente precisa de ver. Em vez de
--    mexer naquela função (é grande e serve sete vistas), o acompanhamento
--    passa a ter a sua. Sem security definer: quem vê é quem a RLS deixa ver.
create or replace function public.espaco_progresso(processo uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  conta uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then
    return jsonb_build_object('processo', null, 'erro', 'sem_acesso');
  end if;

  return jsonb_build_object(
    'processo', (
      select jsonb_build_object('estado', c.status, 'desde', c.status_changed_at,
        'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
      from public.irs_cases c where c.id = processo),
    'prontidao', public.prontidao_do_processo(processo),
    'contagens', jsonb_build_object(
      'membros', (select count(*) from public.case_people where case_id = processo),
      'rendimentos', (select count(*) from public.income_records where case_id = processo),
      'documentos', (select count(*) from public.documents where case_id = processo)),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo
      order by k.created_at desc limit 1),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'consultas_senha', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'pessoa', p.full_name, 'em', v.viewed_at
      ) order by v.viewed_at desc), '[]'::jsonb)
      from public.tax_credential_views v
      join public.people p on p.id = v.person_id
      where v.account_id = conta)
  );
end $$;

grant execute on function public.espaco_progresso(uuid) to authenticated;

-- Source: 202610270034_devolvido_e_editavel.sql
-- Três correções ao fluxo, encontradas a verificar a migração anterior.
--
-- 1. O can_edit_case só considerava "collecting" editável. Um processo
--    devolvido ficaria em "returned" e o cliente não lhe podia tocar — era o
--    contrário do que "devolvido para completar" significa.
-- 2. A prontidão usava o can_edit_case como porta de leitura: assim que o
--    processo saísse da recolha, o cliente deixava de ver a sua própria lista.
--    A leitura passa a ser quem lê a conta.
-- 3. O submeter_processo tinha o mesmo problema, e ainda ficava bloqueado por
--    um pagamento pendente (o Multibanco demora horas). A autorização é ler a
--    conta; o estado já é verificado à parte.

create or replace function public.can_edit_case(account uuid, caseid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_staff() or (
    public.can_read_account(account)
    and exists(select 1 from public.irs_cases c
                where c.id = caseid and c.account_id = account
                  and c.status in ('collecting','returned'))
    and not exists(select 1 from public.irs_checkouts p
                    where p.case_id = caseid and p.state in ('creating','pending','unknown')))
$$;

create or replace function public.prontidao_do_processo(processo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conta uuid;
  titular public.people;
  com_senha boolean;
  com_2fa int;
  rendimentos int;
  documentos int;
  pago text;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then return '[]'::jsonb; end if;
  if not public.can_read_account(conta) then
    return '[]'::jsonb;
  end if;

  select p.* into titular
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and cp.relationship = 'titular' limit 1;

  select exists(select 1 from public.tax_credentials tc where tc.person_id = titular.id)
    into com_senha;

  select count(*) into com_2fa
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and p.tax_two_factor;

  select count(*) into rendimentos from public.income_records where case_id = processo;
  select count(*) into documentos from public.documents where case_id = processo;

  select k.state into pago from public.irs_checkouts k
   where k.case_id = processo order by k.created_at desc limit 1;

  return jsonb_build_array(
    jsonb_build_object(
      'chave','titular', 'de','cliente', 'bloqueia', true,
      'rotulo','Dados do titular',
      'estado', case when titular.nif is not null and titular.birth_date is not null
                     then 'ok' else 'falta' end,
      'detalhe', case when titular.nif is null then 'Falta o NIF.'
                      when titular.birth_date is null then 'Falta a data de nascimento.'
                      else coalesce(titular.full_name,'') end),
    jsonb_build_object(
      'chave','senha', 'de','cliente', 'bloqueia', true,
      'rotulo','Senha das Finanças do titular',
      'estado', case when com_senha then 'ok' else 'falta' end,
      'detalhe', case when com_senha then 'Guardada e cifrada.'
                      else 'Sem a senha não consigo entrar no Portal das Finanças.' end),
    jsonb_build_object(
      'chave','rendimentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Rendimentos declarados',
      'estado', case when rendimentos > 0 then 'ok' else 'falta' end,
      'detalhe', case when rendimentos > 0 then rendimentos || ' linha(s).'
                      else 'Declare pelo menos uma categoria de rendimento.' end),
    jsonb_build_object(
      'chave','documentos', 'de','cliente', 'bloqueia', false,
      'rotulo','Documentos enviados',
      'estado', case when documentos > 0 then 'ok' else 'atencao' end,
      'detalhe', case when documentos > 0 then documentos || ' ficheiro(s).'
                      else 'Ainda não enviou documentos. Pode submeter sem eles, mas posso pedir-lhos.' end),
    jsonb_build_object(
      'chave','dois_fatores', 'de','gabinete', 'bloqueia', false,
      'rotulo','Autenticação de dois fatores',
      'estado', case when com_2fa > 0 then 'atencao' else 'ok' end,
      'detalhe', case when com_2fa > 0
                      then com_2fa || ' pessoa(s) com 2FA: é preciso contacto na hora da submissão.'
                      else 'Ninguém do agregado tem 2FA ativo.' end),
    jsonb_build_object(
      'chave','pagamento', 'de','cliente', 'bloqueia', false,
      'rotulo','Pagamento da preparação',
      'estado', case pago when 'paid' then 'ok' when 'pending' then 'atencao' else 'falta' end,
      'detalhe', case pago
                   when 'paid' then 'Recebido.'
                   when 'pending' then 'A aguardar liquidação — o Multibanco pode levar horas.'
                   when 'failed' then 'A última tentativa falhou.'
                   else 'Ainda não foi pago.' end)
  );
end $$;

create or replace function public.submeter_processo(processo uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  lista jsonb;
  faltas text[];
begin
  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;
  if not public.can_read_account(conta) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if actual not in ('collecting','returned') then
    raise exception 'O processo já foi submetido.' using errcode = 'P0004';
  end if;

  lista := public.prontidao_do_processo(processo);
  select array_agg(x->>'rotulo') into faltas
    from jsonb_array_elements(lista) x
   where (x->>'bloqueia')::boolean and x->>'estado' = 'falta';

  if faltas is not null then
    return jsonb_build_object('ok', false, 'faltas', to_jsonb(faltas), 'prontidao', lista);
  end if;

  update public.irs_cases
     set status = 'submitted_by_client',
         submitted_by_client_at = coalesce(submitted_by_client_at, now())
   where id = processo;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(), 'Processo submetido',
            'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.');

  return jsonb_build_object('ok', true, 'estado', 'submitted_by_client');
end $$;

-- Source: 202610270035_fechar_as_funcoes_novas.sql
-- As funções novas ficaram executáveis pelo anon do PostgREST: o Supabase tem
-- um default privilege no schema public que dá execute ao anon em cada função
-- criada, por isso o "revoke from public" do core não chega — é preciso tirar
-- ao anon pelo nome. As três verificam a autorização por dentro, mas uma função
-- que só serve quem está autenticado não deve estar à porta.

revoke all on function
  public.prontidao_do_processo(uuid),
  public.submeter_processo(uuid),
  public.espaco_progresso(uuid)
from public, anon;

grant execute on function
  public.prontidao_do_processo(uuid),
  public.submeter_processo(uuid),
  public.espaco_progresso(uuid)
to authenticated;

-- Source: 202610280036_pagamento_sem_bloqueios_presos.sql
-- Uma tentativa de pagamento que falhava antes de chegar ao Stripe ficava em
-- "creating" para sempre — e o can_edit_case trancava o processo inteiro
-- enquanto houvesse uma: o cliente deixava de conseguir acrescentar membros,
-- guardar senhas ou rendimentos. Era essa a origem de metade dos "dá erro".
--
-- 1. "creating" deixa de trancar: é um estado de segundos, não um pagamento.
-- 2. Uma tentativa "creating" com mais de 15 minutos é abandonada (cancelled)
--    quando o cliente volta a pagar, em vez de ser devolvida outra vez.
-- 3. O pagamento confirmado também submete um processo devolvido.

create or replace function public.can_edit_case(account uuid, caseid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_staff() or (
    public.can_read_account(account)
    and exists(select 1 from public.irs_cases c
                where c.id = caseid and c.account_id = account
                  and c.status in ('collecting','returned'))
    and not exists(select 1 from public.irs_checkouts p
                    where p.case_id = caseid and p.state in ('pending','unknown')))
$$;

-- O gatilho da recolha repetia a mesma regra com "creating" lá dentro.
create or replace function public.guard_case_collection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare target_case uuid; target_account uuid;
begin
  if tg_op = 'DELETE' then target_case := old.case_id; target_account := old.account_id;
  else target_case := new.case_id; target_account := new.account_id; end if;
  perform 1 from public.irs_cases c where c.id = target_case and c.account_id = target_account for update;
  if not public.can_edit_case(target_account, target_case) then
    raise exception 'Collection locked' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.begin_irs_checkout(
  account uuid, process uuid, coupon text default '', expected_total integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare quote jsonb; attempt public.irs_checkouts;
begin
  if not public.can_read_account(account) or not exists(
       select 1 from public.account_access a
        where a.account_id = account and a.user_id = auth.uid()
          and a.role = 'owner' and a.active and a.irs) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  perform 1 from public.irs_cases c where c.id = process and c.account_id = account for update;
  if not found then raise exception 'Process unavailable'; end if;

  -- Tentativas presas a meio da criação: abandonadas.
  update public.irs_checkouts set state = 'cancelled'
   where case_id = process and state = 'creating' and created_at < now() - interval '15 minutes';

  select * into attempt from public.irs_checkouts
   where case_id = process and state in ('creating','pending','unknown','paid')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('id', attempt.id, 'state', attempt.state,
      'checkout_url', attempt.checkout_url, 'sessao', attempt.provider_order_id,
      'created', false, 'amount_cents', attempt.amount_cents);
  end if;

  if not exists(select 1 from public.irs_cases c where c.id = process and c.status in ('collecting','returned')) then
    raise exception 'Case is not collecting';
  end if;
  if not exists(select 1 from public.case_people where case_id = process and relationship = 'titular') then
    raise exception 'Holder missing';
  end if;
  if exists(select 1 from public.documents where case_id = process and state = 'pending') then
    raise exception 'Finish pending uploads first';
  end if;

  perform 1 from public.discount_codes d
   where d.code = upper(btrim(coalesce(coupon,'')))
      or d.id = (select p.forced_discount_id from public.profiles p where p.id = auth.uid())
   order by d.id for update;
  quote := public.quote_irs_checkout(account, process, coupon);
  if expected_total is not null and expected_total <> (quote->>'total_cents')::integer then
    raise exception 'Price changed. Review the quote again.' using errcode = '22023';
  end if;

  insert into public.irs_checkouts(account_id, case_id, user_id, quote, amount_cents, discount_id, discount_cents)
  values (account, process, auth.uid(), quote, (quote->>'total_cents')::integer,
          (quote->>'discount_id')::uuid, (quote->>'discount_cents')::integer)
  returning * into attempt;

  if attempt.amount_cents = 0 then
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt.id;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = process;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (account, process, auth.uid(), 'Processo submetido',
            'Processo enviado para revisão com desconto integral. Não representa submissão à AT.');
  end if;

  return jsonb_build_object('id', attempt.id,
    'state', case when attempt.amount_cents = 0 then 'paid' else 'creating' end,
    'created', true, 'amount_cents', attempt.amount_cents);
end $$;

create or replace function public.finalizar_pagamento_stripe(
  attempt uuid, provider_id text, provider_reference text, pago boolean, falhou boolean,
  provider_amount integer, provider_currency text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare payment public.irs_checkouts;
begin
  select * into strict payment from public.irs_checkouts where id = attempt for update;

  if payment.provider_order_id is distinct from provider_id
     or payment.id::text is distinct from provider_reference
     or payment.amount_cents is distinct from provider_amount
     or lower(provider_currency) is distinct from 'eur' then
    raise exception 'Order mismatch';
  end if;

  if payment.state = 'paid' then return; end if;
  if payment.state not in ('pending','unknown') then raise exception 'Invalid payment state'; end if;

  update public.irs_checkouts set last_checked_at = now() where id = attempt;

  if pago then
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              'Processo submetido',
              'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.');
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;

-- O cliente desiste de um pagamento aberto (para corrigir dados, por exemplo).
-- Só o dono, e só enquanto não está pago.
create or replace function public.cancelar_pagamento_aberto(attempt uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare payment public.irs_checkouts;
begin
  select * into payment from public.irs_checkouts where id = attempt for update;
  if not found or payment.user_id is distinct from auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if payment.state not in ('creating','pending') then return payment.state; end if;
  update public.irs_checkouts set state = 'cancelled' where id = attempt;
  return payment.provider_order_id;
end $$;

revoke all on function public.cancelar_pagamento_aberto(uuid) from public, anon;
grant execute on function public.cancelar_pagamento_aberto(uuid) to authenticated;

-- A tentativa que ficou presa a 27/10 e trancava o processo de ensaio.
update public.irs_checkouts set state = 'cancelled'
 where state = 'creating' and created_at < now() - interval '15 minutes';

-- Source: 202610280037_membro_e_senha_juntos.sql
-- O membro do agregado e a sua senha das Finanças passam a ser gravados na
-- mesma transação. Antes eram duas chamadas: se a segunda falhasse, o membro
-- ficava sem senha e o cliente via um erro a meio. A senha tem de ser indicada
-- ao criar o membro — é a regra do gabinete — e pode ser substituída depois.
--
-- O id de um membro novo vem de fora (p_id_novo) porque a senha é cifrada no
-- servidor da aplicação com o id da pessoa no AAD, antes de chegar aqui.

drop function if exists public.guardar_membro_agregado(uuid, text, text, text, uuid, date, boolean);

create or replace function public.guardar_membro_agregado(
  processo uuid, p_nome text, p_nif text, p_relacao text,
  p_pessoa uuid default null, p_nascimento date default null,
  p_dois_fatores boolean default false,
  p_id_novo uuid default null, p_cifrada text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  destino uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_edit_case(conta, processo) then
    raise exception 'O processo não pode ser alterado neste momento.' using errcode = '42501';
  end if;
  if p_nome is null or length(btrim(p_nome)) < 2 then
    raise exception 'Indique o nome completo.' using errcode = '22023';
  end if;
  if p_nif !~ '^[0-9]{9}$' then
    raise exception 'O NIF tem nove dígitos.' using errcode = '22023';
  end if;
  if p_nascimento is null then
    raise exception 'Indique a data de nascimento.' using errcode = '22023';
  end if;
  if p_nascimento > current_date then
    raise exception 'A data de nascimento não pode ser no futuro.' using errcode = '22023';
  end if;
  if p_relacao not in ('titular','conjuge','descendente','ascendente','outro') then
    raise exception 'Escolha a relação de parentesco.' using errcode = '22023';
  end if;

  if p_pessoa is null then
    if p_cifrada is null or p_id_novo is null then
      raise exception 'Indique a senha do Portal das Finanças desta pessoa.' using errcode = '22023';
    end if;
    if exists(select 1 from public.case_people cp join public.people p on p.id = cp.person_id
               where cp.case_id = processo and p.nif = p_nif) then
      raise exception 'Já existe alguém com este NIF no agregado.' using errcode = '23505';
    end if;
    insert into public.people(id, account_id, full_name, birth_date, nif, tax_two_factor)
      values (p_id_novo, conta, btrim(p_nome), p_nascimento, p_nif, p_dois_fatores)
      returning id into destino;
  else
    update public.people
       set full_name = btrim(p_nome), birth_date = p_nascimento,
           nif = p_nif, tax_two_factor = p_dois_fatores
     where id = p_pessoa and account_id = conta
     returning id into destino;
    if destino is null then
      raise exception 'Membro não encontrado nesta conta.' using errcode = '22023';
    end if;
    if p_cifrada is null and not exists(select 1 from public.tax_credentials where person_id = destino) then
      raise exception 'Indique a senha do Portal das Finanças desta pessoa.' using errcode = '22023';
    end if;
  end if;

  insert into public.case_people(account_id, case_id, person_id, relationship)
    values (conta, processo, destino, p_relacao)
    on conflict (case_id, person_id) do update set relationship = excluded.relationship;

  if p_cifrada is not null then
    insert into public.tax_credentials(person_id, account_id, encrypted_password, updated_at, updated_by)
      values (destino, conta, p_cifrada, now(), auth.uid())
    on conflict (person_id) do update
      set encrypted_password = excluded.encrypted_password,
          updated_at = now(), updated_by = excluded.updated_by;
  end if;

  return destino;
end $$;

revoke all on function public.guardar_membro_agregado(uuid,text,text,text,uuid,date,boolean,uuid,text) from public, anon;
grant execute on function public.guardar_membro_agregado(uuid,text,text,text,uuid,date,boolean,uuid,text) to authenticated;

-- O titular da minha conta, para a senha do onboarding. Sem RLS pelo meio:
-- no próprio pedido em que o perfil acabou de ser criado, a leitura através
-- das políticas era o elo frágil.
create or replace function public.meu_titular()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('processo', c.id, 'pessoa', cp.person_id)
    from public.account_access a
    join public.irs_cases c on c.account_id = a.account_id
    join public.case_people cp on cp.case_id = c.id and cp.relationship = 'titular'
   where a.user_id = auth.uid() and a.role = 'owner' and a.active
   order by c.tax_year desc
   limit 1
$$;

revoke all on function public.meu_titular() from public, anon;
grant execute on function public.meu_titular() to authenticated;
revoke all on function public.guardar_senha_financas(uuid,uuid,text) from public, anon;
grant execute on function public.guardar_senha_financas(uuid,uuid,text) to authenticated;

-- Source: 202610280038_cancelar_tentativa.sql
-- Fecha uma tentativa de pagamento que o servidor não conseguiu abrir no
-- Stripe (ou cuja sessão expirou), para a seguinte começar limpa. Só a chave
-- de serviço: é o servidor que decide, depois de falar com o Stripe.

create or replace function public.cancelar_tentativa_de_pagamento(attempt uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.irs_checkouts set state = 'cancelled'
   where id = attempt and state in ('creating','pending','unknown');
$$;

revoke all on function public.cancelar_tentativa_de_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.cancelar_tentativa_de_pagamento(uuid) to service_role;

-- Source: 202610280039_congelar_so_com_ordem_aberta.sql
-- Com uma ordem aberta no fornecedor (pending/unknown), o processo fica
-- congelado para todos — também para o gabinete: o valor já foi apresentado
-- ao cliente e não pode mudar debaixo dele. Uma tentativa ainda em "creating"
-- não congela nada.

create or replace function public.guard_case_collection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare target_case uuid; target_account uuid;
begin
  if tg_op = 'DELETE' then target_case := old.case_id; target_account := old.account_id;
  else target_case := new.case_id; target_account := new.account_id; end if;
  perform 1 from public.irs_cases c where c.id = target_case and c.account_id = target_account for update;
  if not public.can_edit_case(target_account, target_case)
     or exists(select 1 from public.irs_checkouts p
                where p.case_id = target_case and p.state in ('pending','unknown')) then
    raise exception 'Collection locked' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Source: 202610280040_indices_e_politicas.sql
-- Revisão de desempenho para centenas de utilizadores em simultâneo.
-- 1. Índices nas chaves estrangeiras que não os tinham: sem eles, cada apagar
--    ou atualizar na tabela-mãe percorre a tabela-filha inteira.
-- 2. As duas políticas que chamavam auth.uid() por linha passam a chamá-lo uma
--    vez por consulta, como as restantes.

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

-- Source: 202610280041_consola_do_gabinete.sql
-- A consola do contabilista, refeita. Mantém todas as chaves que já existiam
-- (o relatório usa-as) e acrescenta o que faltava para trabalhar:
--   * na fila: NIF, contactos, mensagens por responder, estado do pagamento,
--     e totais por fase;
--   * no processo: contactos, morada, residência fiscal e a prontidão;
--   * consultar a senha das Finanças, com registo (o cliente vê-o);
--   * registar a descarga de um documento (o cliente vê-a).

create or replace function public.espaco_gabinete(vista text, processo uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  dados jsonb := jsonb_build_object('vista', vista, 'processo', processo);
begin
  if not public.is_staff() then
    return dados || jsonb_build_object('erro', 'sem_acesso');
  end if;

  if vista = 'fila' then
    return dados || jsonb_build_object(
      'processos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id, 'cliente', a.name, 'estado', c.status, 'desde', c.status_changed_at,
          'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
          'nif', dono.nif, 'email', dono.email, 'telefone', dono.phone,
          'titulares', (select count(*) from public.case_people cp where cp.case_id = c.id),
          'rendimentos', (select count(*) from public.income_records ir where ir.case_id = c.id),
          'documentos', (select count(*) from public.documents d where d.case_id = c.id),
          'por_rever', (select count(*) from public.documents d
                         where d.case_id = c.id and d.state = 'uploaded'
                           and not exists(select 1 from public.document_downloads dd where dd.document_id = d.id)),
          'mensagens', (select count(*) from public.messages m where m.case_id = c.id),
          'por_responder', (
            select count(*) from public.messages m
             where m.case_id = c.id
               and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
               and m.created_at > coalesce((
                 select max(m2.created_at) from public.messages m2
                  join public.staff_users s2 on s2.user_id = m2.author_id
                  where m2.case_id = c.id), '-infinity'::timestamptz)),
          'dois_fatores', exists(select 1 from public.case_people cp
                                  join public.people p on p.id = cp.person_id
                                  where cp.case_id = c.id and p.tax_two_factor),
          'pago', exists(select 1 from public.irs_checkouts k
                          where k.case_id = c.id and k.state = 'paid'),
          'pagamento', (select k.state from public.irs_checkouts k where k.case_id = c.id
                         order by k.created_at desc limit 1),
          'total', (select k.amount_cents from public.irs_checkouts k where k.case_id = c.id
                     order by k.created_at desc limit 1)
        ) order by
          case c.status
            when 'submitted_by_client' then 0 when 'divergence' then 1 when 'accepted' then 2
            when 'validation' then 3 when 'approved' then 4 when 'submitting' then 5
            when 'returned' then 6 when 'filed' then 7 when 'monitoring' then 8
            when 'assessed' then 9 when 'collecting' then 10 else 11 end,
          c.status_changed_at), '[]'::jsonb)
        from public.irs_cases c
        join public.client_accounts a on a.id = c.account_id
        left join lateral (
          select pr.nif, pr.email, pr.phone from public.profiles pr
            join public.account_access aa on aa.user_id = pr.id
           where aa.account_id = c.account_id and aa.role = 'owner'
           limit 1) dono on true),
      'totais', jsonb_build_object(
        'abertos', (select count(*) from public.irs_cases where status <> 'closed'),
        'a_rever', (select count(*) from public.irs_cases
                     where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
        'recolha', (select count(*) from public.irs_cases where status in ('collecting','returned')),
        'entregues', (select count(*) from public.irs_cases where status in ('filed','monitoring','assessed','closed')),
        'pagos', (select count(*) from public.irs_checkouts where state = 'paid'),
        'receita', (select coalesce(sum(amount_cents), 0) from public.irs_checkouts where state = 'paid'),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null),
        'por_responder', (
          select count(distinct m.case_id) from public.messages m
           where not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
             and m.created_at > coalesce((
               select max(m2.created_at) from public.messages m2
                join public.staff_users s2 on s2.user_id = m2.author_id
                where m2.case_id = m.case_id), '-infinity'::timestamptz)))
    );
  end if;

  if vista = 'mensagens' then
    return dados || jsonb_build_object(
      'conversas', (
        select coalesce(jsonb_agg(x order by x->>'ultima' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
            'processo', c.id, 'cliente', a.name,
            'total', (select count(*) from public.messages m where m.case_id = c.id),
            'ultima', (select max(m.created_at) from public.messages m where m.case_id = c.id),
            'resumo', (select left(m.body, 140) from public.messages m where m.case_id = c.id
                        order by m.created_at desc limit 1),
            'por_responder', exists(
              select 1 from public.messages m
              where m.case_id = c.id
                and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
                and m.created_at > coalesce((
                  select max(m2.created_at) from public.messages m2
                  join public.staff_users s2 on s2.user_id = m2.author_id
                  where m2.case_id = c.id), '-infinity'::timestamptz))
          ) as x
          from public.irs_cases c
          join public.client_accounts a on a.id = c.account_id
          where exists(select 1 from public.messages m where m.case_id = c.id)
        ) t)
    );
  end if;

  if vista = 'pagamentos' then
    return dados || jsonb_build_object(
      'pagamentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', k.id, 'processo', k.case_id, 'cliente', a.name,
          'estado', k.state, 'total', k.amount_cents, 'desconto', k.discount_cents,
          'criado', k.created_at, 'pago_em', k.paid_at
        ) order by k.created_at desc), '[]'::jsonb)
        from public.irs_checkouts k
        join public.client_accounts a on a.id = k.account_id
        where k.state <> 'cancelled')
    );
  end if;

  if vista = 'alertas' then
    return dados || jsonb_build_object(
      'alertas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', t.id, 'tipo', t.kind, 'em', t.created_at,
          'pessoa', p.full_name, 'cliente', a.name, 'conta', t.account_id,
          'processo', (select c.id from public.irs_cases c
                        where c.account_id = t.account_id order by c.tax_year desc limit 1)
        ) order by t.created_at desc), '[]'::jsonb)
        from public.task_alerts t
        join public.client_accounts a on a.id = t.account_id
        left join public.people p on p.id = t.person_id
        where t.resolved_at is null)
    );
  end if;

  if processo is null then
    return dados || jsonb_build_object('erro', 'sem_processo');
  end if;

  return dados || jsonb_build_object(
    'cabecalho', (
      select jsonb_build_object(
        'cliente', a.name, 'conta', c.account_id,
        'estado', c.status, 'desde', c.status_changed_at,
        'ano', c.tax_year, 'submetido_em', c.submitted_by_client_at,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction,
        'nif', dono.nif, 'residencia', dono.tax_residence,
        'email', dono.email, 'telefone', dono.phone, 'morada', dono.address,
        'representante', case when dono.rep_name is null then null else jsonb_build_object(
          'nome', dono.rep_name, 'nif', dono.rep_nif, 'email', dono.rep_email, 'telefone', dono.rep_phone) end)
      from public.irs_cases c
      join public.client_accounts a on a.id = c.account_id
      left join lateral (
        select pr.* from public.profiles pr
          join public.account_access aa on aa.user_id = pr.id
         where aa.account_id = c.account_id and aa.role = 'owner'
         limit 1) dono on true
      where c.id = processo),
    'membros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.full_name, 'nascimento', p.birth_date, 'nif', p.nif,
        'relacao', cp.relationship, 'dois_fatores', p.tax_two_factor,
        'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
        'consultas', (select count(*) from public.tax_credential_views v where v.person_id = p.id),
        'ultima_consulta', (select max(v.viewed_at) from public.tax_credential_views v where v.person_id = p.id)
      ) order by case cp.relationship when 'titular' then 0 else 1 end, p.full_name), '[]'::jsonb)
      from public.case_people cp
      join public.people p on p.id = cp.person_id
      where cp.case_id = processo),
    'imoveis', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pa.id, 'nome', pa.label, 'tipo', pa.kind, 'descricao', pa.description) order by pa.label), '[]'::jsonb)
      from public.property_assets pa where pa.case_id = processo),
    'rendimentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ir.id, 'categoria', ir.category, 'tipo', ir.kind, 'titulo', ir.title,
        'titular', ir.person_id, 'imovel', ir.property_id, 'valor', ir.amount_cents,
        'nota', ir.details, 'irs_jovem', ir.young_irs, 'estuda_trabalha', ir.studies_and_works,
        'ambito', ir.foreign_scope, 'compra_em', ir.acquired_on, 'venda_em', ir.sold_on,
        'compra', ir.acquisition_cents, 'venda', ir.sale_cents, 'despesas', ir.expenses_cents,
        'hpp', ir.hpp_reinvestment, 'hpp_credito', ir.hpp_credit_cents, 'hpp_feito', ir.hpp_done
      ) order by ir.category, ir.created_at), '[]'::jsonb)
      from public.income_records ir where ir.case_id = processo),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
        'nome', d.file_name, 'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at,
        'imovel', (select pa.label from public.property_assets pa where pa.id = d.property_id),
        'descargas', (select count(*) from public.document_downloads dd where dd.document_id = d.id)
      ) order by d.created_at desc), '[]'::jsonb)
      from public.documents d where d.case_id = processo),
    'notas', (
      select coalesce(jsonb_object_agg(cn.tab, cn.body), '{}'::jsonb)
      from public.case_notes cn where cn.case_id = processo),
    'deducoes', (
      select to_jsonb(cd) - 'case_id' - 'account_id'
      from public.case_deductions cd where cd.case_id = processo),
    'mensagens', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id, 'corpo', m.body, 'em', m.created_at,
        'do_gabinete', exists(select 1 from public.staff_users s where s.user_id = m.author_id)
      ) order by m.created_at), '[]'::jsonb)
      from public.messages m where m.case_id = processo),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at,
                                'desconto', k.discount_cents, 'detalhe', k.quote)
      from public.irs_checkouts k where k.case_id = processo and k.state <> 'cancelled'
      order by k.created_at desc limit 1),
    'prontidao', public.prontidao_do_processo(processo)
  );
end $$;

-- A senha das Finanças, para mim. Fica registado quem, quando e de quem —
-- é esse registo que o cliente vê no Acompanhamento.
create or replace function public.consultar_senha_financas(p_pessoa uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare guardada public.tax_credentials;
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into guardada from public.tax_credentials where person_id = p_pessoa;
  if not found then
    raise exception 'Esta pessoa não tem senha guardada.' using errcode = '22023';
  end if;
  insert into public.tax_credential_views(person_id, account_id, viewed_by)
    values (p_pessoa, guardada.account_id, auth.uid());
  return guardada.encrypted_password;
end $$;

revoke all on function public.consultar_senha_financas(uuid) from public, anon;
grant execute on function public.consultar_senha_financas(uuid) to authenticated;

-- A descarga de um documento por mim, registada.
create or replace function public.registar_descarga(documento uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare doc public.documents;
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into doc from public.documents where id = documento;
  if not found or doc.state not in ('uploaded','reviewed') then
    raise exception 'Documento indisponível.' using errcode = '22023';
  end if;
  insert into public.document_downloads(document_id, account_id, downloaded_by)
    values (doc.id, doc.account_id, auth.uid());
  return doc.storage_path;
end $$;

revoke all on function public.registar_descarga(uuid) from public, anon;
grant execute on function public.registar_descarga(uuid) to authenticated;

-- Source: 202610280042_contagens_do_gabinete.sql
-- As contagens do menu lateral da gestão, que agora tem o gabinete do IRS
-- dentro: o que espera por mim, as conversas por responder e os alertas.
-- Corre em cada página, por isso é só isto — nada da fila inteira.

create or replace function public.contagens_do_gabinete()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.is_staff() then '{}'::jsonb else jsonb_build_object(
    'a_rever', (select count(*) from public.irs_cases
                 where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
    'alertas', (select count(*) from public.task_alerts where resolved_at is null),
    'por_responder', (
      select count(*) from public.irs_cases c
       where exists(
         select 1 from public.messages m
          where m.case_id = c.id
            and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
            and m.created_at > coalesce((
              select max(m2.created_at) from public.messages m2
               join public.staff_users s2 on s2.user_id = m2.author_id
               where m2.case_id = c.id), '-infinity'::timestamptz)))
  ) end
$$;

revoke all on function public.contagens_do_gabinete() from public, anon;
grant execute on function public.contagens_do_gabinete() to authenticated;

-- Source: 202610280043_cliente_mensagens_e_pagar_e_submeter.sql
-- O espaço do cliente, revisto.
--
-- 1. Mensagens: o espaco_irs decidia se uma mensagem era do gabinete
--    perguntando à tabela staff_users — que o cliente não pode ler. Todas as
--    mensagens pareciam do cliente, incluindo as minhas respostas. Passa a
--    decidir pelo autor: se não fui eu (cliente), é do gabinete.
-- 2. O acompanhamento (e o novo Início) trazem a última mensagem do gabinete,
--    para o menu poder assinalar uma resposta nova.
-- 3. "Pagar e submeter" é um momento só. O pagamento não abre enquanto faltar
--    algo que impeça a submissão (dados do titular, senha, rendimentos), e a
--    submissão sem pagamento fica reservada a um processo devolvido, que já
--    foi pago.

do $mensagens$
declare d text;
  velho constant text := '''do_gabinete'', exists(select 1 from public.staff_users s where s.user_id = m.author_id)';
  novo constant text := '''do_gabinete'', m.author_id is distinct from auth.uid()';
begin
  d := pg_get_functiondef('public.espaco_irs(text,uuid)'::regprocedure);
  if position(velho in d) = 0 then
    if position(novo in d) > 0 then return; end if;
    raise exception 'espaco_irs: padrão das mensagens não encontrado';
  end if;
  execute replace(d, velho, novo);
end $mensagens$;

create or replace function public.espaco_progresso(processo uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  conta uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then
    return jsonb_build_object('processo', null, 'erro', 'sem_acesso');
  end if;

  return jsonb_build_object(
    'processo', (
      select jsonb_build_object('estado', c.status, 'desde', c.status_changed_at,
        'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
      from public.irs_cases c where c.id = processo),
    'prontidao', public.prontidao_do_processo(processo),
    'contagens', jsonb_build_object(
      'membros', (select count(*) from public.case_people where case_id = processo),
      'rendimentos', (select count(*) from public.income_records where case_id = processo),
      'documentos', (select count(*) from public.documents where case_id = processo),
      'mensagens', (select count(*) from public.messages where case_id = processo)),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo and k.state <> 'cancelled'
      order by k.created_at desc limit 1),
    'ultima_do_gabinete', (
      select jsonb_build_object('corpo', left(m.body, 280), 'em', m.created_at)
      from public.messages m
      where m.case_id = processo and m.author_id is distinct from auth.uid()
      order by m.created_at desc limit 1),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'consultas_senha', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'pessoa', p.full_name, 'em', v.viewed_at
      ) order by v.viewed_at desc), '[]'::jsonb)
      from public.tax_credential_views v
      join public.people p on p.id = v.person_id
      where v.account_id = conta)
  );
end $$;

-- O pagamento só abre com o processo pronto a submeter.
do $pagar$
declare d text;
  ancora constant text := 'if exists(select 1 from public.documents where case_id = process and state = ''pending'') then';
  guarda constant text := 'if exists(select 1 from jsonb_array_elements(public.prontidao_do_processo(process)) x
               where (x->>''bloqueia'')::boolean and x->>''estado'' = ''falta'') then
    raise exception ''Incomplete case'' using errcode = ''22023'';
  end if;
  ';
begin
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure);
  if position('Incomplete case' in d) > 0 then return; end if;
  if position(ancora in d) = 0 then raise exception 'begin_irs_checkout: âncora não encontrada'; end if;
  execute replace(d, ancora, guarda || ancora);
end $pagar$;

-- Submeter sem pagar só serve a quem já pagou (um processo devolvido).
do $submeter$
declare d text;
  ancora constant text := 'lista := public.prontidao_do_processo(processo);';
  guarda constant text := 'if not exists(select 1 from public.irs_checkouts k where k.case_id = processo and k.state = ''paid'') then
    raise exception ''Payment required'' using errcode = ''P0005'';
  end if;

  ';
begin
  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure);
  if position('Payment required' in d) > 0 then return; end if;
  if position(ancora in d) = 0 then raise exception 'submeter_processo: âncora não encontrada'; end if;
  execute replace(d, ancora, guarda || ancora);
end $submeter$;

-- Source: 202610280044_progresso_com_pagamento.sql
-- O Início, o Acompanhamento e o Pagamento do cliente leem a mesma função:
-- o pagamento precisa da prontidão (para dizer o que falta antes de pagar) e
-- o Início precisa do pagamento. Acrescenta-se o detalhe do último pagamento.

do $p$
declare d text;
  velho constant text := 'select jsonb_build_object(''estado'', k.state, ''total'', k.amount_cents, ''pago_em'', k.paid_at)';
  novo constant text := 'select jsonb_build_object(''id'', k.id, ''estado'', k.state, ''total'', k.amount_cents, ''pago_em'', k.paid_at, ''desconto'', k.discount_cents, ''detalhe'', k.quote)';
begin
  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure);
  if position(novo in d) > 0 then return; end if;
  if position(velho in d) = 0 then raise exception 'espaco_progresso: padrão do pagamento não encontrado'; end if;
  execute replace(d, velho, novo);
end $p$;

-- Source: 202610280045_eliminar_e_registo_de_atividade.sql
-- 1. Eliminar um utilizador por completo.
--    A eliminação antiga só bloqueava o acesso e anonimizava o perfil: os
--    processos, rendimentos, documentos, mensagens e pagamentos ficavam na
--    base. Agora apaga-se tudo o que é da conta de que o utilizador é titular
--    (e o que ele próprio escreveu noutras), quer tenha confirmado o email quer
--    não. Os ficheiros saem do armazenamento pelo servidor (o Storage não deixa
--    apagar por SQL); a autenticação sai pela API de administração. A ficha no
--    Cegid não é tocada: vive lá e é lá que se gere.
--
-- 2. Registo de atividade, para prova numa contestação de pagamento: entradas
--    na conta (com IP e browser), início do pagamento, confirmação pelo Stripe,
--    ficha e fatura no Cegid — o que até aqui não ficava guardado em lado
--    nenhum.
--
-- 3. relatorio_de_atividade: a linha do tempo completa de um processo, com
--    tudo o que a base sabe, numa consulta só.

-- ------------------------------------------------------ registo de atividade
create table if not exists public.registo_atividade (
  id bigint generated always as identity primary key,
  user_id uuid,
  account_id uuid,
  case_id uuid,
  tipo text not null check (length(tipo) between 2 and 60),
  detalhe text check (detalhe is null or length(detalhe) <= 2000),
  ip text check (ip is null or length(ip) <= 64),
  agente text check (agente is null or length(agente) <= 400),
  criado_em timestamptz not null default now()
);
create index if not exists registo_atividade_conta_idx on public.registo_atividade(account_id, criado_em);
create index if not exists registo_atividade_user_idx on public.registo_atividade(user_id, criado_em);
alter table public.registo_atividade enable row level security;
-- Sem políticas: ninguém lê nem escreve diretamente. Escreve-se pela função
-- abaixo (o próprio utilizador) ou pela chave de serviço (o sistema).

create or replace function public.registar_atividade(
  p_tipo text, p_detalhe text default null, p_case uuid default null,
  p_ip text default null, p_agente text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then return; end if;
  if p_case is not null then
    select account_id into conta from public.irs_cases where id = p_case;
    if conta is null or not public.can_read_account(conta) then return; end if;
  else
    select a.account_id into conta from public.account_access a
     where a.user_id = auth.uid() and a.role = 'owner' limit 1;
  end if;
  insert into public.registo_atividade(user_id, account_id, case_id, tipo, detalhe, ip, agente)
  values (auth.uid(), conta, p_case, left(p_tipo, 60), left(p_detalhe, 2000), left(p_ip, 64), left(p_agente, 400));
end $$;

revoke all on function public.registar_atividade(text,text,uuid,text,text) from public, anon;
grant execute on function public.registar_atividade(text,text,uuid,text,text) to authenticated;

-- ------------------------------------------------------------- eliminação
create or replace function public.eliminar_utilizador(target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  contas uuid[];
  caminhos text[];
  pago boolean;
begin
  if not public.is_platform_owner() or target = auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if exists(select 1 from public.staff_users where user_id = target) then
    raise exception 'Uma conta do gabinete não se elimina por aqui.' using errcode = '22023';
  end if;

  -- As contas de que é titular saem por inteiro.
  select coalesce(array_agg(account_id), '{}') into contas
    from public.account_access where user_id = target and role = 'owner';

  select exists(select 1 from public.irs_checkouts where account_id = any(contas) and state = 'paid') into pago;

  select coalesce(array_agg(storage_path), '{}') into caminhos
    from public.documents where account_id = any(contas) or uploaded_by = target;

  -- Primeiro os pagamentos: com um pagamento aberto, o gatilho da recolha
  -- recusaria apagar rendimentos e documentos.
  delete from public.irs_checkouts where account_id = any(contas) or user_id = target;
  delete from public.documents where account_id = any(contas) or uploaded_by = target;
  delete from public.income_records where account_id = any(contas);
  delete from public.property_assets where account_id = any(contas);
  delete from public.case_notes where account_id = any(contas);
  delete from public.case_deductions where account_id = any(contas);
  delete from public.messages where account_id = any(contas) or author_id = target;
  delete from public.progress_events where account_id = any(contas) or author_id = target;
  delete from public.task_alerts where account_id = any(contas);
  delete from public.invitation_requests where account_id = any(contas) or requested_by = target;
  delete from public.household_invitations where account_id = any(contas);
  update public.household_invitations set accepted_by = null where accepted_by = target;
  delete from public.tax_credential_views where account_id = any(contas);
  delete from public.tax_credentials where account_id = any(contas);
  delete from public.case_people where account_id = any(contas);
  delete from public.people where account_id = any(contas);
  delete from public.irs_cases where account_id = any(contas);
  delete from public.payments where account_id = any(contas);
  delete from public.invoices where account_id = any(contas);
  delete from public.registo_atividade where account_id = any(contas) or user_id = target;
  delete from public.account_access where account_id = any(contas) or user_id = target;
  delete from public.client_accounts where id = any(contas);

  -- O que aponta para o perfil e impediria apagar a autenticação.
  delete from public.company_users where user_id = target;
  update public.staff_users set managed_by = null where managed_by = target;
  update public.profiles set forced_discount_id = null where id = target;
  delete from public.discount_codes d where d.allowed_user = target
     and not exists(select 1 from public.irs_checkouts k where k.discount_id = d.id)
     and not exists(select 1 from public.profiles p where p.forced_discount_id = d.id);
  update public.discount_codes set allowed_user = null, active = false where allowed_user = target;

  -- O perfil sai aqui (e não só em cascata da autenticação): serve também
  -- para limpar contas que a eliminação antiga deixou anonimizadas.
  delete from public.profiles where id = target;

  insert into public.management_audit(actor_id, target_id, action)
    values (auth.uid(), target, 'user_fully_deleted');

  return jsonb_build_object('caminhos', to_jsonb(caminhos), 'contas', cardinality(contas), 'tinha_pagamento', pago);
end $$;

revoke all on function public.eliminar_utilizador(uuid) from public, anon;
grant execute on function public.eliminar_utilizador(uuid) to authenticated;

-- Para a confirmação: o que vai ser apagado, e se houve pagamento (uma
-- contestação pode chegar até 120 dias depois).
create or replace function public.antes_de_eliminar(target uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with contas as (
    select account_id from public.account_access where user_id = target and role = 'owner')
  select case when not public.is_platform_owner() then '{}'::jsonb else jsonb_build_object(
    'confirmado', (select u.email_confirmed_at is not null from auth.users u where u.id = target),
    'processos', (select count(*) from public.irs_cases where account_id in (select account_id from contas)),
    'rendimentos', (select count(*) from public.income_records where account_id in (select account_id from contas)),
    'documentos', (select count(*) from public.documents where account_id in (select account_id from contas)),
    'mensagens', (select count(*) from public.messages where account_id in (select account_id from contas)),
    'pago_em', (select max(paid_at) from public.irs_checkouts where account_id in (select account_id from contas) and state = 'paid'),
    'processo', (select c.id from public.irs_cases c where c.account_id in (select account_id from contas) order by c.tax_year desc limit 1)
  ) end
$$;

revoke all on function public.antes_de_eliminar(uuid) from public, anon;
grant execute on function public.antes_de_eliminar(uuid) to authenticated;

-- ------------------------------------------------- relatório de atividade
create or replace function public.relatorio_de_atividade(processo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conta uuid;
  titular uuid;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then raise exception 'Processo não encontrado.' using errcode = '22023'; end if;
  select user_id into titular from public.account_access
   where account_id = conta and role = 'owner' limit 1;

  return jsonb_build_object(
    'cliente', (
      select jsonb_build_object(
        'nome', p.full_name, 'nif', p.nif, 'email', coalesce(nullif(p.email, ''), u.email),
        'telefone', p.phone, 'morada', p.address, 'nascimento', p.birth_date,
        'conta_criada', u.created_at, 'email_confirmado', u.email_confirmed_at,
        'ultimo_acesso', u.last_sign_in_at, 'utilizador', p.id)
      from public.profiles p left join auth.users u on u.id = p.id
      where p.id = titular),
    'processo', (
      select jsonb_build_object('id', c.id, 'ano', c.tax_year, 'estado', c.status,
        'aberto', c.created_at, 'submetido', c.submitted_by_client_at,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
      from public.irs_cases c where c.id = processo),
    'pagamentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', k.id, 'estado', k.state, 'total', k.amount_cents, 'desconto', k.discount_cents,
        'criado', k.created_at, 'pago_em', k.paid_at, 'sessao', k.provider_order_id, 'detalhe', k.quote)
        order by k.created_at), '[]'::jsonb)
      from public.irs_checkouts k where k.case_id = processo),
    'eventos', (
      select coalesce(jsonb_agg(e order by e->>'em', e->>'ordem'), '[]'::jsonb) from (
        select jsonb_build_object('em', u.created_at, 'ordem', '01', 'origem', 'Cliente',
               'evento', 'Conta criada na plataforma', 'detalhe', u.email) e
          from auth.users u where u.id = titular
        union all
        select jsonb_build_object('em', u.email_confirmed_at, 'ordem', '02', 'origem', 'Cliente',
               'evento', 'Email confirmado', 'detalhe', 'Através da ligação enviada para ' || u.email)
          from auth.users u where u.id = titular and u.email_confirmed_at is not null
        union all
        select jsonb_build_object('em', l.accepted_at, 'ordem', '03', 'origem', 'Cliente',
               'evento', 'Termos e Condições e Política de Privacidade aceites',
               'detalhe', 'Versão ' || l.terms_version || coalesce(' · ' || l.source, ''))
          from public.legal_acceptances l where l.user_id = titular
        union all
        select jsonb_build_object('em', p.onboarding_completed_at, 'ordem', '04', 'origem', 'Cliente',
               'evento', 'Dados pessoais preenchidos',
               'detalhe', concat_ws(' · ', p.full_name, 'NIF ' || p.nif, p.phone, p.address))
          from public.profiles p where p.id = titular and p.onboarding_completed_at is not null
        union all
        select jsonb_build_object('em', c.created_at, 'ordem', '05', 'origem', 'Sistema',
               'evento', 'Processo de IRS ' || c.tax_year || ' aberto', 'detalhe', 'Processo ' || c.id)
          from public.irs_cases c where c.id = processo
        union all
        select jsonb_build_object('em', pe.created_at, 'ordem', '06', 'origem', 'Cliente',
               'evento', 'Pessoa do agregado registada',
               'detalhe', concat_ws(' · ', pe.full_name, 'NIF ' || pe.nif, cp.relationship))
          from public.case_people cp join public.people pe on pe.id = cp.person_id
         where cp.case_id = processo
        union all
        select jsonb_build_object('em', tc.updated_at, 'ordem', '07', 'origem', 'Cliente',
               'evento', 'Senha do Portal das Finanças guardada (cifrada)', 'detalhe', pe.full_name)
          from public.tax_credentials tc join public.people pe on pe.id = tc.person_id
         where tc.account_id = conta
        union all
        select jsonb_build_object('em', ir.created_at, 'ordem', '08', 'origem', 'Cliente',
               'evento', 'Rendimento declarado',
               'detalhe', concat_ws(' · ', coalesce(ir.kind, ir.title), ir.category,
                 (select pe.full_name from public.people pe where pe.id = ir.person_id),
                 case when ir.amount_cents is not null then to_char(ir.amount_cents / 100.0, 'FM999G999G990D00') || ' €' end))
          from public.income_records ir where ir.case_id = processo
        union all
        select jsonb_build_object('em', d.created_at, 'ordem', '09', 'origem', 'Cliente',
               'evento', 'Documento enviado',
               'detalhe', concat_ws(' · ', d.kind, d.description, d.file_name, round(d.file_size / 1024.0) || ' KB'))
          from public.documents d where d.case_id = processo
        union all
        select jsonb_build_object('em', k.created_at, 'ordem', '10', 'origem', 'Cliente',
               'evento', 'Pagamento iniciado',
               'detalhe', to_char(k.amount_cents / 100.0, 'FM999G990D00') || ' € · tentativa ' || k.id)
          from public.irs_checkouts k where k.case_id = processo
        union all
        select jsonb_build_object('em', k.paid_at, 'ordem', '11', 'origem', 'Stripe',
               'evento', 'Pagamento confirmado',
               'detalhe', to_char(k.amount_cents / 100.0, 'FM999G990D00') || ' € · sessão ' || coalesce(k.provider_order_id, '—'))
          from public.irs_checkouts k where k.case_id = processo and k.state = 'paid' and k.paid_at is not null
        union all
        select jsonb_build_object('em', coalesce(k.last_checked_at, k.created_at), 'ordem', '12', 'origem', 'Stripe',
               'evento', case k.state when 'failed' then 'Pagamento falhado ou expirado' else 'Pagamento cancelado' end,
               'detalhe', 'Tentativa ' || k.id)
          from public.irs_checkouts k where k.case_id = processo and k.state in ('failed','cancelled')
        union all
        select jsonb_build_object('em', ev.created_at, 'ordem', '13',
               'origem', case when exists(select 1 from public.staff_users s where s.user_id = ev.author_id) then 'Contabilista' else 'Cliente' end,
               'evento', ev.title, 'detalhe', ev.body)
          from public.progress_events ev where ev.case_id = processo
        union all
        select jsonb_build_object('em', m.created_at, 'ordem', '14',
               'origem', case when exists(select 1 from public.staff_users s where s.user_id = m.author_id) then 'Contabilista' else 'Cliente' end,
               'evento', case when exists(select 1 from public.staff_users s where s.user_id = m.author_id)
                              then 'Mensagem enviada ao cliente' else 'Mensagem enviada ao contabilista' end,
               'detalhe', '"' || left(m.body, 600) || '"')
          from public.messages m where m.case_id = processo
        union all
        select jsonb_build_object('em', dd.downloaded_at, 'ordem', '15', 'origem', 'Contabilista',
               'evento', 'Documento aberto pelo contabilista',
               'detalhe', concat_ws(' · ', d.kind, d.description, d.file_name))
          from public.document_downloads dd join public.documents d on d.id = dd.document_id
         where d.case_id = processo
        union all
        select jsonb_build_object('em', v.viewed_at, 'ordem', '16', 'origem', 'Contabilista',
               'evento', 'Senha do Portal das Finanças consultada', 'detalhe', pe.full_name)
          from public.tax_credential_views v join public.people pe on pe.id = v.person_id
         where v.account_id = conta
        union all
        select jsonb_build_object('em', r.criado_em, 'ordem', '17',
               'origem', case
                 when r.tipo like 'cegid%' then 'Cegid Business'
                 when r.tipo like 'stripe%' then 'Stripe'
                 when r.user_id is not null and exists(select 1 from public.staff_users s where s.user_id = r.user_id) then 'Contabilista'
                 when r.user_id is null then 'Sistema'
                 else 'Cliente' end,
               'evento', case r.tipo
                 when 'login' then 'Entrada na conta'
                 when 'registo' then 'Registo submetido'
                 when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'stripe_evento' then 'Notificação do Stripe recebida'
                 when 'cegid_ficha' then 'Ficha de cliente criada no Cegid Business'
                 when 'cegid_ficha_falhou' then 'Criação da ficha no Cegid recusada'
                 when 'cegid_fatura' then 'Fatura-recibo criada no Cegid Business'
                 else r.tipo end,
               'detalhe', concat_ws(' · ', r.detalhe, 'IP ' || r.ip, r.agente))
          from public.registo_atividade r
         where r.account_id = conta or (r.user_id = titular and r.account_id is null)
      ) t where e->>'em' is not null)
  );
end $$;

revoke all on function public.relatorio_de_atividade(uuid) from public, anon;
grant execute on function public.relatorio_de_atividade(uuid) to authenticated;

-- Source: 202610280046_resumo_para_eliminar.sql
-- O resumo de cada utilizador de uma página da lista, numa consulta só: se
-- confirmou o email, o que tem (processos, rendimentos, documentos,
-- mensagens) e se pagou — para a confirmação da eliminação dizer o que se
-- vai perder e avisar quando há um pagamento que pode ser contestado.

drop function if exists public.antes_de_eliminar(uuid);

create or replace function public.resumo_para_eliminar(ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.is_staff() then '{}'::jsonb else coalesce(jsonb_object_agg(u.id, jsonb_build_object(
    'confirmado', u.email_confirmed_at is not null,
    'ultimo_acesso', u.last_sign_in_at,
    'processos', (select count(*) from public.irs_cases c join public.account_access a on a.account_id = c.account_id
                   where a.user_id = u.id and a.role = 'owner'),
    'rendimentos', (select count(*) from public.income_records r join public.account_access a on a.account_id = r.account_id
                     where a.user_id = u.id and a.role = 'owner'),
    'documentos', (select count(*) from public.documents d join public.account_access a on a.account_id = d.account_id
                    where a.user_id = u.id and a.role = 'owner'),
    'mensagens', (select count(*) from public.messages m join public.account_access a on a.account_id = m.account_id
                   where a.user_id = u.id and a.role = 'owner'),
    'pago_em', (select max(k.paid_at) from public.irs_checkouts k join public.account_access a on a.account_id = k.account_id
                 where a.user_id = u.id and a.role = 'owner' and k.state = 'paid'),
    'processo', (select c.id from public.irs_cases c join public.account_access a on a.account_id = c.account_id
                  where a.user_id = u.id and a.role = 'owner' order by c.tax_year desc limit 1)
  )), '{}'::jsonb) end
  from auth.users u where u.id = any(ids)
$$;

revoke all on function public.resumo_para_eliminar(uuid[]) from public, anon;
grant execute on function public.resumo_para_eliminar(uuid[]) to authenticated;

-- Source: 202610280047_relatorio_em_portugues.sql
-- O relatório de atividade mostrava os códigos internos (employment,
-- conjuge…) onde devia dizer "Trabalho dependente", "Cônjuge"…

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('Trabalho dependente' in d) > 0 then return; end if;
  if position('coalesce(ir.kind, ir.title), ir.category,' in d) = 0 or position('''NIF '' || pe.nif, cp.relationship))' in d) = 0 then
    raise exception 'relatorio_de_atividade: padrões não encontrados';
  end if;
  d := replace(d, 'coalesce(ir.kind, ir.title), ir.category,',
    'coalesce(ir.kind, ir.title), case ir.category when ''employment'' then ''Trabalho dependente'' when ''pension'' then ''Pensões''
       when ''independent'' then ''Trabalho independente'' when ''securities'' then ''Capitais e valores mobiliários''
       when ''property_rent'' then ''Rendas'' when ''property_sale'' then ''Mais-valias de imóveis''
       when ''foreign_income'' then ''Rendimentos estrangeiros'' else ir.category end,');
  d := replace(d, '''NIF '' || pe.nif, cp.relationship))',
    '''NIF '' || pe.nif, case cp.relationship when ''titular'' then ''Titular'' when ''conjuge'' then ''Cônjuge''
       when ''descendente'' then ''Descendente'' when ''ascendente'' then ''Ascendente'' else cp.relationship end))');
  execute d;
end $x$;

-- Source: 202610280048_euros_em_portugues.sql
-- Os valores do relatório saíam no formato inglês (150,000.00 €).

create or replace function public.euros_pt(cents bigint)
returns text language sql immutable set search_path = '' as $$
  select translate(to_char(cents / 100.0, 'FM999G999G990D00'), ',.', '.,') || ' €'
$$;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('public.euros_pt(' in d) > 0 then return; end if;
  d := replace(d, 'to_char(ir.amount_cents / 100.0, ''FM999G999G990D00'') || '' €''', 'public.euros_pt(ir.amount_cents)');
  d := replace(d, 'to_char(k.amount_cents / 100.0, ''FM999G990D00'') || '' €', 'public.euros_pt(k.amount_cents) || ''');
  if position('to_char(' in d) > 0 then raise exception 'relatorio_de_atividade: ficou um to_char por trocar'; end if;
  execute d;
end $x$;

-- Source: 202610280049_documentos_e_senha_guardada.sql
-- Três falhas que o cliente via como "não gravou".
--
-- 1. Os documentos ficavam pendentes para sempre. O ficheiro chegava ao
--    Storage, mas o passo seguinte (marcar como enviado, com o separador, o
--    imóvel e a descrição) era recusado: o cliente só pode atualizar a coluna
--    state. O documento ficava 'pending', não aparecia em nenhum separador do
--    gabinete e bloqueava o pagamento. A conclusão passa para uma função que
--    confirma que o ficheiro chegou.
-- 2. As fotografias são guardadas em WebP, mas a preparação só aceitava PDF,
--    JPEG e PNG. Repetir o envio do mesmo ficheiro depois de uma falha também
--    era recusado; agora retoma-se.
-- 3. A senha das Finanças estava guardada, mas o espaço do cliente lê como o
--    cliente e a tabela das senhas só deixa ler o gabinete: dizia sempre "por
--    indicar".

create or replace function public.prepare_irs_document(
  account uuid, process uuid, record uuid, doc_kind text, original_name text,
  mime text, size_bytes bigint, hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare existing public.documents; document_id uuid := gen_random_uuid(); path text; reuse boolean := false;
begin
  if not public.can_edit_case(account, process) then raise exception 'Not authorized' using errcode = '42501'; end if;
  if hash is null or hash !~ '^[a-f0-9]{64}$'
     or mime not in ('application/pdf','image/jpeg','image/png','image/webp')
     or size_bytes is null or size_bytes not between 1 and 10485760 then
    raise exception 'Invalid file';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(account::text || process::text || hash, 0));

  -- Um envio que ficou a meio, da mesma pessoa: retoma-se no mesmo sítio.
  select * into existing from public.documents
   where account_id = account and case_id = process and content_hash = hash
     and state = 'pending' and uploaded_by = auth.uid()
   order by created_at desc limit 1;
  if found then
    if not exists(select 1 from storage.objects o
                   where o.bucket_id = 'irs-documents' and o.name = existing.storage_path) then
      update public.documents
         set kind = doc_kind, income_id = record, file_name = original_name,
             mime_type = mime, file_size = size_bytes
       where id = existing.id;
    end if;
    return jsonb_build_object('id', existing.id, 'path', existing.storage_path, 'reused', false, 'retomado', true);
  end if;

  select * into existing from public.documents
   where account_id = account and case_id = process and content_hash = hash
   order by (state in ('uploaded','reviewed')) desc, created_at limit 1;
  if found then
    if existing.state not in ('uploaded','reviewed') then
      raise exception 'Identical file pending or rejected. Contact the professional.';
    end if;
    if existing.file_size <> size_bytes or existing.mime_type <> mime then raise exception 'File metadata mismatch'; end if;
    path := existing.storage_path; reuse := true;
  else
    path := account::text || '/' || process::text || '/' || document_id::text;
  end if;
  insert into public.documents(id, account_id, case_id, income_id, kind, file_name, storage_path, mime_type, file_size, content_hash)
  values (document_id, account, process, record, doc_kind, original_name, path, mime, size_bytes, hash);
  return jsonb_build_object('id', document_id, 'path', path, 'reused', reuse);
end $$;

/* Concluir o envio: só quem o começou, só com o ficheiro já no Storage, e
   com o separador, o imóvel e a descrição validados aqui. Repetir é inócuo. */
create or replace function public.concluir_documento(
  p_documento uuid, p_categoria text, p_imovel uuid, p_descricao text)
returns void language plpgsql security definer set search_path = '' as $$
declare doc public.documents; descricao text := nullif(btrim(coalesce(p_descricao, '')), '');
begin
  select * into doc from public.documents where id = p_documento for update;
  if not found or doc.uploaded_by is distinct from auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if doc.state in ('uploaded','reviewed') then return; end if;
  if doc.state <> 'pending' then raise exception 'Document not pending' using errcode = '22023'; end if;
  if not public.can_edit_case(doc.account_id, doc.case_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists(select 1 from storage.objects o
                 where o.bucket_id = 'irs-documents' and o.name = doc.storage_path) then
    raise exception 'File not received' using errcode = '22023';
  end if;
  if p_imovel is not null and not exists(
       select 1 from public.property_assets pa
        where pa.id = p_imovel and pa.account_id = doc.account_id and pa.case_id = doc.case_id) then
    raise exception 'Invalid property' using errcode = '22023';
  end if;
  update public.documents
     set state = 'uploaded',
         category = nullif(p_categoria, ''),
         property_id = p_imovel,
         description = case when length(descricao) >= 3 then left(descricao, 200) end
   where id = doc.id;
end $$;
revoke all on function public.concluir_documento(uuid, text, uuid, text) from public, anon;
grant execute on function public.concluir_documento(uuid, text, uuid, text) to authenticated;

/* Quando foi guardada a senha de uma pessoa. A senha cifrada não sai daqui. */
create or replace function public.senha_guardada_em(p_pessoa uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select tc.updated_at from public.tax_credentials tc
   where tc.person_id = p_pessoa and public.can_read_account(tc.account_id)
$$;
revoke all on function public.senha_guardada_em(uuid) from public, anon;
grant execute on function public.senha_guardada_em(uuid) to authenticated;

-- O espaço do cliente: a senha lida pela função acima, e os envios a meio
-- deixam de contar como documentos.
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.espaco_irs(text,uuid)'::regprocedure);
  if position('public.senha_guardada_em(' in d) > 0 then return; end if;
  d := replace(d, '''tem_senha'', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),',
                  '''tem_senha'', public.senha_guardada_em(p.id) is not null,');
  d := replace(d, '''senha_em'', (select tc.updated_at from public.tax_credentials tc where tc.person_id = p.id),',
                  '''senha_em'', public.senha_guardada_em(p.id),');
  d := replace(d, 'from public.documents d where d.case_id = processo)',
                  'from public.documents d where d.case_id = processo and d.state <> ''pending'')');
  d := replace(d, '(select count(*) from public.documents where case_id = processo)',
                  '(select count(*) from public.documents where case_id = processo and state <> ''pending'')');
  if position('tax_credentials' in d) > 0 then raise exception 'espaco_irs: ficou uma leitura direta das senhas'; end if;
  execute d;

  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure);
  d := replace(d, '(select count(*) from public.documents where case_id = processo)',
                  '(select count(*) from public.documents where case_id = processo and state <> ''pending'')');
  execute d;

  d := pg_get_functiondef('public.prontidao_do_processo(uuid)'::regprocedure);
  d := replace(d, 'select count(*) into documentos from public.documents where case_id = processo;',
                  'select count(*) into documentos from public.documents where case_id = processo and state <> ''pending'';');
  execute d;

  -- Só trava o pagamento um envio em curso. Um que ficou a meio há mais de
  -- quinze minutos foi abandonado e não pode prender o processo.
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure);
  d := replace(d, 'where case_id = process and state = ''pending'') then',
                  'where case_id = process and state = ''pending'' and created_at > now() - interval ''15 minutes'') then');
  if position('interval ''15 minutes''' in d) = 0 then raise exception 'begin_irs_checkout: condição dos envios não encontrada'; end if;
  execute d;
end $x$;

-- Source: 202610280050_pagar_depois_de_submeter.sql
-- Pagar e submeter deixam de ser o mesmo passo obrigatório.
--
-- Até aqui só se submetia depois de pagar, e só se pagava com o processo em
-- recolha: quem submetesse (ou visse o processo avançar) já não conseguia
-- pagar. Agora:
--   - submeter não exige pagamento;
--   - o pagamento fica disponível em qualquer fase até ao fecho do processo;
--   - pagar com o processo ainda em recolha continua a submetê-lo (o botão
--     "Pagar e submeter"); pagar depois só regista o pagamento.

create or replace function public.submeter_processo(processo uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  conta uuid;
  actual text;
  lista jsonb;
  faltas text[];
  pago boolean;
begin
  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;
  if not public.can_read_account(conta) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if actual not in ('collecting','returned') then
    raise exception 'O processo já foi submetido.' using errcode = 'P0004';
  end if;
  lista := public.prontidao_do_processo(processo);
  select array_agg(x->>'rotulo') into faltas
    from jsonb_array_elements(lista) x
   where (x->>'bloqueia')::boolean and x->>'estado' = 'falta';

  if faltas is not null then
    return jsonb_build_object('ok', false, 'faltas', to_jsonb(faltas), 'prontidao', lista);
  end if;

  pago := exists(select 1 from public.irs_checkouts k where k.case_id = processo and k.state = 'paid');

  update public.irs_cases
     set status = 'submitted_by_client',
         submitted_by_client_at = coalesce(submitted_by_client_at, now())
   where id = processo;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(), 'Processo submetido',
            case when pago
              then 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.'
              else 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar. O pagamento pode ser feito a qualquer momento no separador Pagamento.'
            end);

  return jsonb_build_object('ok', true, 'estado', 'submitted_by_client', 'pago', pago);
end $$;

create or replace function public.begin_irs_checkout(
  account uuid, process uuid, coupon text default '', expected_total integer default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare quote jsonb; attempt public.irs_checkouts; estado text; em_recolha boolean;
begin
  if not public.can_read_account(account) or not exists(
       select 1 from public.account_access a
        where a.account_id = account and a.user_id = auth.uid()
          and a.role = 'owner' and a.active and a.irs) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select c.status into estado from public.irs_cases c
   where c.id = process and c.account_id = account for update;
  if not found then raise exception 'Process unavailable'; end if;
  em_recolha := estado in ('collecting','returned');

  update public.irs_checkouts set state = 'cancelled'
   where case_id = process and state = 'creating' and created_at < now() - interval '15 minutes';

  select * into attempt from public.irs_checkouts
   where case_id = process and state in ('creating','pending','unknown','paid')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('id', attempt.id, 'state', attempt.state,
      'checkout_url', attempt.checkout_url, 'sessao', attempt.provider_order_id,
      'created', false, 'amount_cents', attempt.amount_cents);
  end if;

  if estado = 'closed' then
    raise exception 'Case is closed';
  end if;
  if not exists(select 1 from public.case_people where case_id = process and relationship = 'titular') then
    raise exception 'Holder missing';
  end if;
  -- Em recolha, pagar também submete: tem de estar pronto. Depois de
  -- submetido, a prontidão já foi verificada na submissão.
  if em_recolha and exists(
       select 1 from jsonb_array_elements(public.prontidao_do_processo(process)) x
        where (x->>'bloqueia')::boolean and x->>'estado' = 'falta') then
    raise exception 'Incomplete case' using errcode = '22023';
  end if;
  if em_recolha and exists(
       select 1 from public.documents
        where case_id = process and state = 'pending' and created_at > now() - interval '15 minutes') then
    raise exception 'Finish pending uploads first';
  end if;

  perform 1 from public.discount_codes d
   where d.code = upper(btrim(coalesce(coupon,'')))
      or d.id = (select p.forced_discount_id from public.profiles p where p.id = auth.uid())
   order by d.id for update;
  quote := public.quote_irs_checkout(account, process, coupon);
  if expected_total is not null and expected_total <> (quote->>'total_cents')::integer then
    raise exception 'Price changed. Review the quote again.' using errcode = '22023';
  end if;

  insert into public.irs_checkouts(account_id, case_id, user_id, quote, amount_cents, discount_id, discount_cents)
  values (account, process, auth.uid(), quote, (quote->>'total_cents')::integer,
          (quote->>'discount_id')::uuid, (quote->>'discount_cents')::integer)
  returning * into attempt;

  if attempt.amount_cents = 0 then
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt.id;
    if em_recolha then
      update public.irs_cases set status = 'submitted_by_client',
             submitted_by_client_at = coalesce(submitted_by_client_at, now())
       where id = process;
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (account, process, auth.uid(), 'Processo submetido',
              'Processo enviado para revisão com desconto integral. Não representa submissão à AT.');
    else
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (account, process, auth.uid(), 'Pagamento registado', 'Desconto integral: nada a pagar.');
    end if;
  end if;

  return jsonb_build_object('id', attempt.id,
    'state', case when attempt.amount_cents = 0 then 'paid' else 'creating' end,
    'created', true, 'amount_cents', attempt.amount_cents);
end $$;

create or replace function public.finalizar_pagamento_stripe(
  attempt uuid, provider_id text, provider_reference text, pago boolean, falhou boolean,
  provider_amount integer, provider_currency text)
returns void language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts; submetido boolean;
begin
  select * into strict payment from public.irs_checkouts where id = attempt for update;
  if payment.provider_order_id is distinct from provider_id
     or payment.id::text is distinct from provider_reference
     or payment.amount_cents is distinct from provider_amount
     or lower(provider_currency) is distinct from 'eur' then
    raise exception 'Order mismatch';
  end if;
  if payment.state = 'paid' then return; end if;
  if payment.state not in ('pending','unknown') then raise exception 'Invalid payment state'; end if;
  update public.irs_checkouts set last_checked_at = now() where id = attempt;
  if pago then
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    -- Pagar com o processo em recolha é "pagar e submeter".
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.'
                else 'Pagamento confirmado. A fatura-recibo segue para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;

-- Source: 202610280051_relatorio_submissao_aceite.sql
-- O relatório de atividade passa a nomear a submissão feita antes de pagar,
-- com o que o cliente aceitou nesse momento.

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('submissao_aceite' in d) > 0 then return; end if;
  d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                  $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'submissao_aceite' then 'Processo submetido pelo cliente, para pagar depois'$q$);
  if position('submissao_aceite' in d) = 0 then raise exception 'relatorio_de_atividade: rótulo não encontrado'; end if;
  execute d;
end $x$;

-- Source: 202610280052_versao_legal.sql
-- Termos e Política de Privacidade revistos (2026-10-28.1): pagamento pela
-- Stripe, senhas das Finanças cifradas, pagar depois de submeter, livre
-- resolução e registo de atividade com IP.
--
-- A versão estava escrita à mão em sete funções. Passa a viver numa só, e
-- mudar de versão volta a ser uma linha. Quem aceitou a versão anterior é
-- levado a aceitar esta na entrada seguinte (o portal já tem esse ecrã).

create or replace function public.versao_legal()
returns text language sql immutable set search_path = '' as $$ select '2026-10-28.1' $$;
grant execute on function public.versao_legal() to anon, authenticated;

do $x$
declare f record; d text;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proname <> 'versao_legal'
       and pg_get_functiondef(p.oid) like '%''2026-10-23.3''%'
  loop
    d := replace(pg_get_functiondef(f.oid), '''2026-10-23.3''', 'public.versao_legal()');
    execute d;
  end loop;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prokind = 'f'
               and pg_get_functiondef(p.oid) like '%2026-10-23.3%') then
    raise exception 'versão legal: ficou uma função com a versão antiga';
  end if;
end $x$;

-- Source: 202610280053_fechar_funcoes.sql
-- Revisão de segurança das funções.
--
-- 1. Crítico: finalizar_pagamento_stripe e anexar_sessao_de_pagamento podiam
--    ser chamadas por qualquer cliente autenticado (e até sem sessão). Um
--    cliente sabe o id da tentativa, o valor e o id da sessão do Stripe — ou
--    anexava um id inventado e depois "finalizava" com ele. Dava para marcar
--    o processo como pago sem pagar. Passam a ser só do servidor.
-- 2. O anon (quem não entrou) podia executar 24 funções, 17 delas com
--    privilégios de definidor. Nenhuma página pública precisa de nenhuma.
--    Fecham-se todas, e também as que vierem a ser criadas.
-- 3. As políticas que chamam funções aplicavam-se também ao anon; ficam só
--    para quem entrou (o anon continua a ler os avisos públicos).

revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;
revoke all on function public.anexar_sessao_de_pagamento(uuid,text,text) from public, anon, authenticated;
grant execute on function public.anexar_sessao_de_pagamento(uuid,text,text) to service_role;

do $x$
declare f record;
begin
  for f in
    select p.oid, p.oid::regprocedure as assinatura from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  loop
    -- Quem entrou e o servidor mantêm o que já tinham, mesmo que lhes viesse
    -- só pela concessão a public.
    if has_function_privilege('authenticated', f.oid, 'execute') then
      execute format('grant execute on function %s to authenticated', f.assinatura);
    end if;
    if has_function_privilege('service_role', f.oid, 'execute') then
      execute format('grant execute on function %s to service_role', f.assinatura);
    end if;
    execute format('revoke execute on function %s from public, anon', f.assinatura);
  end loop;
end $x$;
alter default privileges in schema public revoke execute on functions from public, anon;

do $x$
declare p record;
begin
  for p in
    select c.relname as tabela, po.polname as politica
      from pg_policy po join pg_class c on c.oid = po.polrelid join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and 0 = any(po.polroles)
       and coalesce(pg_get_expr(po.polqual, po.polrelid), '') || coalesce(pg_get_expr(po.polwithcheck, po.polrelid), '')
           ~ '(is_staff|can_read_account|can_edit_case|readable_accounts)\('
  loop
    execute format('alter policy %I on public.%I to authenticated', p.politica, p.tabela);
  end loop;
end $x$;

-- Source: 202610280054_registo_so_pelo_servidor.sql
-- O registo de atividade é a prova numa contestação de pagamento, mas o
-- cliente podia escrever nele diretamente (registar_atividade aceitava o tipo,
-- o texto, o IP e o browser vindos de quem chamava). Bastava inventar uma
-- "notificação do Stripe" para ela aparecer no relatório como vinda do Stripe.
-- Passa a escrever só o servidor, que sabe quem é o utilizador pela sessão.

create or replace function public.registar_atividade_de(
  p_user uuid, p_tipo text, p_detalhe text default null, p_case uuid default null,
  p_ip text default null, p_agente text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare conta uuid;
begin
  if p_user is null then return; end if;
  if p_case is not null then
    select c.account_id into conta
      from public.irs_cases c join public.account_access a on a.account_id = c.account_id
     where c.id = p_case and a.user_id = p_user and a.active
     limit 1;
    if conta is null then return; end if;
  else
    select a.account_id into conta from public.account_access a
     where a.user_id = p_user and a.role = 'owner' limit 1;
  end if;
  insert into public.registo_atividade(user_id, account_id, case_id, tipo, detalhe, ip, agente)
  values (p_user, conta, p_case, left(p_tipo, 60), left(p_detalhe, 2000), left(p_ip, 64), left(p_agente, 400));
end $$;
revoke all on function public.registar_atividade_de(uuid, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.registar_atividade_de(uuid, text, text, uuid, text, text) to service_role;

drop function if exists public.registar_atividade(text, text, uuid, text, text);

-- Um pagamento confirmado pela Stripe regista-se sempre. Se o cliente
-- cancelou a tentativa num separador e pagou noutro, o dinheiro entrou, mas a
-- base recusava ('Invalid payment state') e o webhook falhava para sempre.
-- Fica pago — e as outras tentativas em aberto desse processo fecham, porque
-- só pode haver uma viva. Se o processo já tinha outro pagamento, este não
-- passa a pago (seria o segundo): fica um alerta urgente para o reembolso.
create or replace function public.finalizar_pagamento_stripe(
  attempt uuid, provider_id text, provider_reference text, pago boolean, falhou boolean,
  provider_amount integer, provider_currency text)
returns void language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts; submetido boolean;
begin
  select * into strict payment from public.irs_checkouts where id = attempt for update;
  if payment.provider_order_id is distinct from provider_id
     or payment.id::text is distinct from provider_reference
     or payment.amount_cents is distinct from provider_amount
     or lower(provider_currency) is distinct from 'eur' then
    raise exception 'Order mismatch';
  end if;
  if payment.state = 'paid' then return; end if;
  if not pago and payment.state not in ('pending','unknown') then return; end if;
  update public.irs_checkouts set last_checked_at = now() where id = attempt;
  if pago then
    if exists(select 1 from public.irs_checkouts k
               where k.case_id = payment.case_id and k.state = 'paid' and k.id <> payment.id) then
      insert into public.task_alerts(account_id, kind) values (payment.account_id, 'pagamento_duplicado');
      return;
    end if;
    update public.irs_checkouts set state = 'cancelled'
     where case_id = payment.case_id and id <> payment.id and state in ('creating','pending','unknown');
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.'
                else 'Pagamento confirmado. A fatura-recibo é emitida em seu nome e enviada para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;
revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;

-- As senhas das Finanças só se escrevem pelas funções que as validam
-- (guardar_membro_agregado e guardar_senha_financas). A escrita direta na
-- tabela, que a aplicação nunca usa, deixava gravar uma senha numa pessoa
-- qualquer desde que a linha apontasse para a própria conta.
drop policy if exists credencial_escreve on public.tax_credentials;
drop policy if exists credencial_atualiza on public.tax_credentials;
revoke insert, update, delete on public.tax_credentials from anon, authenticated;

-- Source: 202610290055_documentos_obrigatorios_e_textos.sql
-- Três mudanças pedidas para o espaço do cliente.
--
-- 1. Os documentos passam a ser obrigatórios em todos os separadores: cada
--    tipo de rendimento declarado (e as deduções, quando há alguma) precisa de
--    pelo menos um documento antes de se poder submeter.
-- 2. O cliente pode apagar um documento enquanto o processo está em
--    preparação. O ficheiro sai do Storage pelo servidor; aqui sai a linha.
-- 3. Os textos que a base escreve passam a um português formal e impessoal,
--    sem "está comigo", "minha fila" ou "aviso-o".

create or replace function public.prontidao_do_processo(processo uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  conta uuid;
  titular public.people;
  com_senha boolean;
  com_2fa int;
  rendimentos int;
  sem_documentos text[];
  pago text;
  deducoes public.case_deductions;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then return '[]'::jsonb; end if;
  if not public.can_read_account(conta) then return '[]'::jsonb; end if;

  select p.* into titular
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and cp.relationship = 'titular' limit 1;

  select exists(select 1 from public.tax_credentials tc where tc.person_id = titular.id) into com_senha;

  select count(*) into com_2fa
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and p.tax_two_factor;

  select count(*) into rendimentos from public.income_records where case_id = processo;

  -- Cada tipo de rendimento declarado precisa de um documento seu. Os
  -- capitais e as mais-valias de ações partilham a categoria na base.
  select array_agg(rotulo order by ordem) into sem_documentos from (
    select distinct
      case ir.category
        when 'employment' then 'Trabalho Dependente'
        when 'pension' then 'Pensões'
        when 'independent' then 'Independente'
        when 'securities' then 'Capitais e Mais-Valias (Ações e Outros)'
        when 'property_rent' then 'Rendas'
        when 'property_sale' then 'Mais-Valias (Imóveis)'
        when 'foreign_income' then 'Rendimentos Estrangeiros'
        else 'Outros rendimentos' end as rotulo,
      case ir.category
        when 'employment' then 1 when 'pension' then 2 when 'independent' then 3
        when 'securities' then 4 when 'property_rent' then 5 when 'property_sale' then 6
        when 'foreign_income' then 7 else 8 end as ordem
      from public.income_records ir
     where ir.case_id = processo
       and not exists(select 1 from public.documents d
                       where d.case_id = processo and d.state <> 'pending'
                         and (d.category = ir.category or d.income_id = ir.id))
  ) t;

  select * into deducoes from public.case_deductions where case_id = processo;
  if (deducoes.ppr or deducoes.ascendant_expenses or deducoes.rented_home)
     and not exists(select 1 from public.documents d
                     where d.case_id = processo and d.state <> 'pending' and d.category = 'deduction') then
    sem_documentos := coalesce(sem_documentos, '{}') || 'Deduções e Benefícios'::text;
  end if;

  select k.state into pago from public.irs_checkouts k
   where k.case_id = processo order by k.created_at desc limit 1;

  return jsonb_build_array(
    jsonb_build_object(
      'chave','titular', 'de','cliente', 'bloqueia', true,
      'rotulo','Dados do titular',
      'estado', case when titular.nif is not null and titular.birth_date is not null then 'ok' else 'falta' end,
      'detalhe', case when titular.nif is null then 'Falta indicar o NIF.'
                      when titular.birth_date is null then 'Falta indicar a data de nascimento.'
                      else coalesce(titular.full_name,'') end),
    jsonb_build_object(
      'chave','senha', 'de','cliente', 'bloqueia', true,
      'rotulo','Senha do Portal das Finanças',
      'estado', case when com_senha then 'ok' else 'falta' end,
      'detalhe', case when com_senha then 'Guardada de forma cifrada.'
                      else 'É necessária para preparar e entregar a declaração.' end),
    jsonb_build_object(
      'chave','rendimentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Rendimentos declarados',
      'estado', case when rendimentos > 0 then 'ok' else 'falta' end,
      'detalhe', case when rendimentos > 0 then rendimentos || ' rendimento(s) declarado(s).'
                      else 'Declare pelo menos um rendimento.' end),
    jsonb_build_object(
      'chave','documentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Documentos de suporte',
      'estado', case when rendimentos = 0 then 'falta'
                     when sem_documentos is null then 'ok' else 'falta' end,
      'detalhe', case when rendimentos = 0 then 'Envie os documentos de cada rendimento que declarar.'
                      when sem_documentos is null then 'Todos os rendimentos têm documentos.'
                      else 'Falta pelo menos um documento em: ' || array_to_string(sem_documentos, ', ') || '.' end),
    jsonb_build_object(
      'chave','dois_fatores', 'de','gabinete', 'bloqueia', false,
      'rotulo','Autenticação de dois fatores',
      'estado', case when com_2fa > 0 then 'atencao' else 'ok' end,
      'detalhe', case when com_2fa > 0
                      then com_2fa || ' pessoa(s) com dois fatores: será necessário contacto no momento da entrega.'
                      else 'Nenhum membro do agregado tem dois fatores ativos.' end),
    jsonb_build_object(
      'chave','pagamento', 'de','cliente', 'bloqueia', false,
      'rotulo','Pagamento da preparação',
      'estado', case pago when 'paid' then 'ok' when 'pending' then 'atencao' else 'falta' end,
      'detalhe', case pago
                   when 'paid' then 'Recebido.'
                   when 'pending' then 'A aguardar confirmação — o Multibanco pode demorar algumas horas.'
                   when 'failed' then 'A última tentativa não foi concluída.'
                   else 'Ainda não foi feito.' end)
  );
end $$;

/* Apagar um documento: só com o processo em preparação (é o que o
   can_edit_case permite), e só os da própria conta. Devolve o caminho do
   ficheiro para o servidor o apagar do Storage — a não ser que outro documento
   do processo use o mesmo ficheiro (os repetidos partilham-no). */
create or replace function public.apagar_documento(p_documento uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare doc public.documents;
begin
  select * into doc from public.documents where id = p_documento for update;
  if not found or not public.can_read_account(doc.account_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not public.can_edit_case(doc.account_id, doc.case_id) then
    raise exception 'Collection locked' using errcode = '42501';
  end if;
  delete from public.document_downloads where document_id = doc.id;
  delete from public.documents where id = doc.id;
  if exists(select 1 from public.documents d where d.storage_path = doc.storage_path) then
    return null;
  end if;
  return doc.storage_path;
end $$;
revoke all on function public.apagar_documento(uuid) from public, anon;
grant execute on function public.apagar_documento(uuid) to authenticated;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.avancar_processo(uuid,text,text,bigint,text)'::regprocedure);
  d := replace(d, 'Recebi o processo e abri-o para análise.', 'O processo foi aceite e está em análise.');
  d := replace(d, 'Estou a conferir os rendimentos e os documentos.', 'Os rendimentos e os documentos estão a ser conferidos.');
  d := replace(d, 'A Autoridade Tributária levantou uma divergência. Vou tratar dela e aviso-o do que for preciso.',
                  'A Autoridade Tributária identificou uma divergência. O assunto está a ser tratado e será informado se for necessário algum elemento.');
  d := replace(d, 'O processo foi submetido e entrou na minha fila.', 'O processo foi submetido e aguarda revisão.');
  execute d;

  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure);
  d := replace(d, 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.',
                  'O processo foi submetido e aguarda revisão. Será informado de cada avanço.');
  execute d;

  d := pg_get_functiondef('public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text)'::regprocedure);
  d := replace(d, 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.',
                  'Pagamento confirmado. O processo foi submetido e aguarda revisão. A declaração ainda não foi entregue na AT.');
  execute d;
end $x$;

-- Source: 202610290056_reembolsos_e_pagamentos_extra.sql
-- Reembolsos e pagamentos adicionais, sempre iniciados pelo gabinete.
--
-- Reembolso: parcial ou total de um pagamento recebido. O gabinete regista-o
-- aqui; o servidor devolve o dinheiro na Stripe e cria a nota de crédito no
-- Cegid em rascunho, e volta aqui para registar o resultado de cada parte.
--
-- Pagamento adicional: um valor combinado com o cliente. O gabinete pede-o;
-- fica uma fatura-recibo em rascunho no Cegid e o cliente paga-o no portal,
-- pela Stripe, como paga a preparação.
--
-- Até aqui só havia um pagamento por processo. Passa a haver um tipo:
-- 'preparacao' (o de sempre) e 'extra'. Tudo o que procurava "o" pagamento do
-- processo (a regra de uma tentativa viva, o congelamento da recolha, a
-- prontidão, os ecrãs) passa a olhar só para a preparação.

alter table public.irs_checkouts add column if not exists tipo text not null default 'preparacao';
alter table public.irs_checkouts drop constraint if exists irs_checkouts_tipo_check;
alter table public.irs_checkouts add constraint irs_checkouts_tipo_check check (tipo in ('preparacao','extra'));
alter table public.irs_checkouts add column if not exists descricao text;
alter table public.irs_checkouts add column if not exists cegid_documento text;
alter table public.irs_checkouts add column if not exists pedido_por uuid;

drop index if exists public.one_live_checkout;
create unique index one_live_checkout on public.irs_checkouts(case_id)
  where tipo = 'preparacao' and state in ('creating','pending','unknown','paid');

create table if not exists public.reembolsos (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  case_id uuid not null references public.irs_cases(id) on delete cascade,
  checkout_id uuid not null references public.irs_checkouts(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  motivo text not null check (length(motivo) between 3 and 500),
  estado text not null default 'a_processar' check (estado in ('a_processar','feito','falhou')),
  stripe_refund_id text,
  stripe_estado text,
  cegid_documento text,
  cegid_erro text,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index if not exists reembolsos_checkout on public.reembolsos(checkout_id);
create index if not exists reembolsos_case on public.reembolsos(case_id);
create index if not exists reembolsos_account on public.reembolsos(account_id);
alter table public.reembolsos enable row level security;
drop policy if exists reembolso_le on public.reembolsos;
create policy reembolso_le on public.reembolsos for select to authenticated
  using (account_id in (select public.readable_accounts()));
grant select on public.reembolsos to authenticated;

/* ---------------------------------------------------------- reembolsos */

create or replace function public.registar_reembolso(p_checkout uuid, p_valor integer, p_motivo text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts; ja integer; novo uuid;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into k from public.irs_checkouts where id = p_checkout for update;
  if not found or k.state <> 'paid' then raise exception 'Só se reembolsa um pagamento recebido.' using errcode = '22023'; end if;
  if k.provider_order_id is null or k.amount_cents = 0 then
    raise exception 'Este pagamento não passou pela Stripe.' using errcode = '22023';
  end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Indique o valor a reembolsar.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Indique o motivo.' using errcode = '22023'; end if;
  select coalesce(sum(amount_cents), 0) into ja from public.reembolsos
   where checkout_id = k.id and estado <> 'falhou';
  if ja + p_valor > k.amount_cents then
    raise exception 'O valor excede o que falta reembolsar (% €).', to_char((k.amount_cents - ja) / 100.0, 'FM999990D00')
      using errcode = '22023';
  end if;
  insert into public.reembolsos(account_id, case_id, checkout_id, amount_cents, motivo, criado_por)
  values (k.account_id, k.case_id, k.id, p_valor, left(btrim(p_motivo), 500), auth.uid())
  returning id into novo;
  return novo;
end $$;

create or replace function public.concluir_reembolso(
  p_reembolso uuid, p_stripe_id text, p_stripe_estado text, p_cegid text, p_cegid_erro text, p_falhou boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.reembolsos;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into r from public.reembolsos where id = p_reembolso for update;
  if not found then raise exception 'Reembolso inexistente.' using errcode = '22023'; end if;
  update public.reembolsos
     set stripe_refund_id = coalesce(p_stripe_id, stripe_refund_id),
         stripe_estado = coalesce(p_stripe_estado, stripe_estado),
         cegid_documento = coalesce(p_cegid, cegid_documento),
         cegid_erro = case when p_cegid is not null then null else coalesce(p_cegid_erro, cegid_erro) end,
         estado = case when p_falhou then 'falhou' when coalesce(p_stripe_id, stripe_refund_id) is not null then 'feito' else estado end
   where id = r.id;
  if not p_falhou and r.estado <> 'feito' and coalesce(p_stripe_id, r.stripe_refund_id) is not null then
    insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (r.account_id, r.case_id, auth.uid(), 'Reembolso processado',
            'Foi processado um reembolso de ' || public.euros_pt(r.amount_cents)
            || '. O valor é devolvido pelo mesmo meio de pagamento, normalmente em 5 a 10 dias úteis.');
  end if;
end $$;

/* --------------------------------------------------- pagamento adicional */

create or replace function public.criar_pagamento_extra(p_processo uuid, p_valor integer, p_descricao text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare caso public.irs_cases; dono uuid; novo uuid; texto text := left(btrim(coalesce(p_descricao, '')), 200);
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into caso from public.irs_cases where id = p_processo;
  if not found then raise exception 'Processo inexistente.' using errcode = '22023'; end if;
  if p_valor is null or p_valor < 50 then raise exception 'O valor mínimo é 0,50 €.' using errcode = '22023'; end if;
  if length(texto) < 3 then raise exception 'Indique a descrição do pagamento.' using errcode = '22023'; end if;
  select a.user_id into dono from public.account_access a
   where a.account_id = caso.account_id and a.role = 'owner' and a.active limit 1;
  if dono is null then raise exception 'O processo não tem titular com acesso.' using errcode = '22023'; end if;
  insert into public.irs_checkouts(account_id, case_id, user_id, quote, amount_cents, tipo, descricao, pedido_por)
  values (caso.account_id, caso.id, dono,
          jsonb_build_object('total_cents', p_valor, 'items', jsonb_build_array(
            jsonb_build_object('code', 'extra', 'label', texto, 'amount_cents', p_valor))),
          p_valor, 'extra', texto, auth.uid())
  returning id into novo;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (caso.account_id, caso.id, auth.uid(), 'Pagamento adicional pedido',
          texto || ' — ' || public.euros_pt(p_valor) || '. Pode pagar no separador Pagamento.');
  return novo;
end $$;

create or replace function public.guardar_cegid_do_pagamento(p_checkout uuid, p_documento text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  update public.irs_checkouts set cegid_documento = left(p_documento, 120) where id = p_checkout;
end $$;

create or replace function public.cancelar_pagamento_extra(p_checkout uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into k from public.irs_checkouts where id = p_checkout and tipo = 'extra' for update;
  if not found then raise exception 'Pagamento adicional inexistente.' using errcode = '22023'; end if;
  if k.state in ('paid','pending','unknown') then
    raise exception 'Este pagamento já foi feito ou está a ser confirmado.' using errcode = '22023';
  end if;
  update public.irs_checkouts set state = 'cancelled' where id = k.id;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (k.account_id, k.case_id, auth.uid(), 'Pagamento adicional anulado', coalesce(k.descricao, '') || ' — anulado.');
  return k.provider_order_id;
end $$;

/* O cliente abre o pagamento adicional. A sessão da Stripe é criada pelo
   servidor; aqui só se confirma que é dele e em que ponto está. */
create or replace function public.iniciar_pagamento_extra(p_checkout uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts;
begin
  select * into k from public.irs_checkouts where id = p_checkout and tipo = 'extra';
  if not found or not public.can_read_account(k.account_id) or not exists(
       select 1 from public.account_access a
        where a.account_id = k.account_id and a.user_id = auth.uid() and a.role = 'owner' and a.active) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if k.state in ('cancelled','failed') then raise exception 'Este pagamento já não está disponível.' using errcode = '22023'; end if;
  return jsonb_build_object('id', k.id, 'state', k.state, 'sessao', k.provider_order_id,
                            'amount_cents', k.amount_cents, 'descricao', k.descricao);
end $$;

revoke all on function public.registar_reembolso(uuid, integer, text) from public, anon;
revoke all on function public.concluir_reembolso(uuid, text, text, text, text, boolean) from public, anon;
revoke all on function public.criar_pagamento_extra(uuid, integer, text) from public, anon;
revoke all on function public.guardar_cegid_do_pagamento(uuid, text) from public, anon;
revoke all on function public.cancelar_pagamento_extra(uuid) from public, anon;
revoke all on function public.iniciar_pagamento_extra(uuid) from public, anon;
grant execute on function public.registar_reembolso(uuid, integer, text) to authenticated;
grant execute on function public.concluir_reembolso(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function public.criar_pagamento_extra(uuid, integer, text) to authenticated;
grant execute on function public.guardar_cegid_do_pagamento(uuid, text) to authenticated;
grant execute on function public.cancelar_pagamento_extra(uuid) to authenticated;
grant execute on function public.iniciar_pagamento_extra(uuid) to authenticated;

/* O cliente cancela uma tentativa aberta. Num pagamento adicional, o pedido
   do gabinete fica de pé: só a sessão da Stripe sai. */
create or replace function public.cancelar_pagamento_aberto(attempt uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts;
begin
  select * into payment from public.irs_checkouts where id = attempt for update;
  if not found or payment.user_id is distinct from auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if payment.state not in ('creating','pending') then return payment.state; end if;
  if payment.tipo = 'extra' then
    update public.irs_checkouts set state = 'creating', provider_order_id = null, checkout_url = null where id = attempt;
  else
    update public.irs_checkouts set state = 'cancelled' where id = attempt;
  end if;
  return payment.provider_order_id;
end $$;

create or replace function public.finalizar_pagamento_stripe(
  attempt uuid, provider_id text, provider_reference text, pago boolean, falhou boolean,
  provider_amount integer, provider_currency text)
returns void language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts; submetido boolean;
begin
  select * into strict payment from public.irs_checkouts where id = attempt for update;
  if payment.provider_order_id is distinct from provider_id
     or payment.id::text is distinct from provider_reference
     or payment.amount_cents is distinct from provider_amount
     or lower(provider_currency) is distinct from 'eur' then
    raise exception 'Order mismatch';
  end if;
  if payment.state = 'paid' then return; end if;
  if not pago and payment.state not in ('pending','unknown') then return; end if;
  update public.irs_checkouts set last_checked_at = now() where id = attempt;

  -- Pagamento adicional: não mexe na fase do processo nem nas outras tentativas.
  if payment.tipo = 'extra' then
    if pago then
      update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id, 'Pagamento adicional recebido',
              coalesce(payment.descricao, 'Pagamento adicional') || ' — ' || public.euros_pt(payment.amount_cents) || '.');
    elsif falhou then
      -- A sessão expirou: o pedido continua de pé para nova tentativa.
      update public.irs_checkouts set state = 'creating', provider_order_id = null, checkout_url = null where id = attempt;
    end if;
    return;
  end if;

  if pago then
    if exists(select 1 from public.irs_checkouts k
               where k.case_id = payment.case_id and k.tipo = 'preparacao' and k.state = 'paid' and k.id <> payment.id) then
      insert into public.task_alerts(account_id, kind) values (payment.account_id, 'pagamento_duplicado');
      return;
    end if;
    update public.irs_checkouts set state = 'cancelled'
     where case_id = payment.case_id and tipo = 'preparacao' and id <> payment.id and state in ('creating','pending','unknown');
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo foi submetido e aguarda revisão. A declaração ainda não foi entregue na AT.'
                else 'Pagamento confirmado. A fatura-recibo é emitida em seu nome e enviada para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;
revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;

do $x$
declare d text; antes text;
begin
  -- A tentativa viva, a limpeza das paradas e o congelamento: só a preparação.
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure); antes := d;
  d := replace(d, 'where case_id = process and state = ''creating'' and created_at',
                  'where case_id = process and tipo = ''preparacao'' and state = ''creating'' and created_at');
  d := replace(d, 'where case_id = process and state in (''creating'',''pending'',''unknown'',''paid'')',
                  'where case_id = process and tipo = ''preparacao'' and state in (''creating'',''pending'',''unknown'',''paid'')');
  if d = antes then raise exception 'begin_irs_checkout: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.guard_case_collection()'::regprocedure); antes := d;
  d := replace(d, 'where p.case_id = target_case and p.state in (''pending'',''unknown'')',
                  'where p.case_id = target_case and p.tipo = ''preparacao'' and p.state in (''pending'',''unknown'')');
  if d = antes then raise exception 'guard_case_collection: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.prontidao_do_processo(uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = processo order by k.created_at desc limit 1;',
                  'where k.case_id = processo and k.tipo = ''preparacao'' order by k.created_at desc limit 1;');
  if d = antes then raise exception 'prontidao_do_processo: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = processo and k.state = ''paid''',
                  'where k.case_id = processo and k.tipo = ''preparacao'' and k.state = ''paid''');
  if d = antes then raise exception 'submeter_processo: nada para trocar'; end if;
  execute d;

  -- O espaço do cliente: o pagamento da preparação, os adicionais e os reembolsos.
  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure); antes := d;
  d := replace(d, 'from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''',
                  'from public.irs_checkouts k where k.case_id = processo and k.tipo = ''preparacao'' and k.state <> ''cancelled''');
  d := replace(d, '    ''ultima_do_gabinete'', (',
'    ''extras'', (
      select coalesce(jsonb_agg(jsonb_build_object(''id'', k.id, ''estado'', k.state, ''total'', k.amount_cents,
        ''descricao'', k.descricao, ''pedido_em'', k.created_at, ''pago_em'', k.paid_at) order by k.created_at desc), ''[]''::jsonb)
      from public.irs_checkouts k where k.case_id = processo and k.tipo = ''extra'' and k.state <> ''cancelled''),
    ''reembolsos'', (
      select coalesce(jsonb_agg(jsonb_build_object(''total'', r.amount_cents, ''motivo'', r.motivo, ''em'', r.criado_em)
        order by r.criado_em desc), ''[]''::jsonb)
      from public.reembolsos r where r.case_id = processo and r.estado = ''feito''),
    ''ultima_do_gabinete'', (');
  if position('''extras''' in d) = 0 or position('k.tipo = ''preparacao''' in d) = 0 then
    raise exception 'espaco_progresso: nada para trocar';
  end if;
  execute d;

  -- A consola do gabinete.
  d := pg_get_functiondef('public.espaco_gabinete(text,uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = c.id', 'where k.case_id = c.id and k.tipo = ''preparacao''');
  d := replace(d, 'from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''',
                  'from public.irs_checkouts k where k.case_id = processo and k.tipo = ''preparacao'' and k.state <> ''cancelled''');
  d := replace(d, '          ''criado'', k.created_at, ''pago_em'', k.paid_at
        ) order by k.created_at desc), ''[]''::jsonb)',
'          ''criado'', k.created_at, ''pago_em'', k.paid_at, ''tipo'', k.tipo, ''descricao'', k.descricao,
          ''reembolsado'', (select coalesce(sum(r.amount_cents), 0) from public.reembolsos r
                             where r.checkout_id = k.id and r.estado = ''feito'')
        ) order by k.created_at desc), ''[]''::jsonb)');
  d := replace(d, '    ''prontidao'', public.prontidao_do_processo(processo)',
'    ''movimentos'', (
      select coalesce(jsonb_agg(jsonb_build_object(
        ''id'', k.id, ''tipo'', k.tipo, ''estado'', k.state, ''total'', k.amount_cents, ''descricao'', k.descricao,
        ''criado'', k.created_at, ''pago_em'', k.paid_at, ''cegid'', k.cegid_documento, ''stripe'', k.provider_order_id,
        ''reembolsos'', (select coalesce(jsonb_agg(jsonb_build_object(
            ''id'', r.id, ''total'', r.amount_cents, ''motivo'', r.motivo, ''estado'', r.estado, ''em'', r.criado_em,
            ''stripe'', r.stripe_refund_id, ''cegid'', r.cegid_documento, ''cegid_erro'', r.cegid_erro)
            order by r.criado_em), ''[]''::jsonb) from public.reembolsos r where r.checkout_id = k.id)
      ) order by k.created_at), ''[]''::jsonb)
      from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''),
    ''prontidao'', public.prontidao_do_processo(processo)');
  if position('''movimentos''' in d) = 0 then raise exception 'espaco_gabinete: movimentos não acrescentados'; end if;
  execute d;

  -- O relatório de atividade nomeia os passos novos.
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('documento_apagado' in d) = 0 then
    d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                    $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'documento_apagado' then 'Documento apagado pelo cliente'
                 when 'reembolso' then 'Reembolso emitido pelo gabinete'
                 when 'reembolso_falhou' then 'Reembolso recusado'
                 when 'pagamento_extra' then 'Pagamento adicional pedido pelo gabinete'$q$);
    execute d;
  end if;
end $x$;

-- Source: 202610290057_emails.sql
-- Os emails que as plataformas enviam: ao cliente (pedidos de pagamento,
-- reembolsos, pagamentos recebidos, mensagens, etapas) e ao gabinete.
--
-- Cada email tem uma chave: "pago:<pagamento>", "reembolso:<id>"... A chave é
-- única, por isso o mesmo aviso nunca sai duas vezes — o webhook da Stripe e a
-- página de regresso confirmam o mesmo pagamento, e só um deles envia. Fica
-- também a prova do que foi comunicado e quando, para o relatório de atividade.

create table if not exists public.emails (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,
  para text not null,
  assunto text not null,
  account_id uuid references public.client_accounts(id) on delete cascade,
  case_id uuid references public.irs_cases(id) on delete cascade,
  estado text not null default 'a_enviar' check (estado in ('a_enviar','enviado','falhou')),
  resend_id text,
  erro text,
  criado_em timestamptz not null default now(),
  enviado_em timestamptz
);
create index if not exists emails_case on public.emails(case_id);
create index if not exists emails_account on public.emails(account_id);
alter table public.emails enable row level security;
-- Só o servidor lê e escreve: nem o cliente nem o anon têm acesso direto.
revoke all on public.emails from anon, authenticated;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('''email''' in d) = 0 then
    d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                    $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'email' then 'Email enviado ao cliente'$q$);
    execute d;
  end if;
end $x$;

-- Source: 202610300060_portal_empresas.sql
-- Plataforma Clientes Empresa (portal.rr-contabilidade.com).
--
-- Os clientes de contabilidade organizada entram com a mesma conta das outras
-- plataformas e veem só as empresas a que estão ligados em company_users, e só
-- se tiverem o acesso Empresas ligado (account_access.business, definido em
-- definir_acessos). O contabilista vê todas.
--
-- 1. Data de corte por empresa. Os saldos e os balancetes só saem até ela:
--    um balancete entregue ao banco tem de ser de um período já revisto. A
--    data fica na empresa e cada alteração fica no histórico.
-- 2. Documentos do mês, até ao dia 10 do mês seguinte (hora de Lisboa). O
--    envio é em dois tempos, como no IRS: a linha nasce pendente, o ficheiro
--    sobe para o Storage privado, e só depois a linha passa a recebida — e é
--    aí que se decide se chegou fora de prazo.
-- 3. Mensagens com o gabinete, prazos (por empresa ou para todas) e um
--    registo de atividade por empresa, que só o servidor e estas funções
--    escrevem.
-- 4. Cache das respostas do Cegid, só para o servidor. A chave inclui a data
--    de corte: mudar a data invalida tudo o que estava guardado.
--
-- Todas as funções novas: sem execute para public/anon; a autorização é
-- verificada dentro de cada uma.

-- ------------------------------------------------------------ data de corte
alter table public.companies
  add column data_corte date,
  add column data_corte_em timestamptz,
  add column data_corte_por uuid;

create table public.empresa_cortes (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  data_corte date,
  nota text check (nota is null or length(nota) <= 500),
  definido_por uuid not null,
  definido_em timestamptz not null default now()
);
create index empresa_cortes_empresa on public.empresa_cortes(company_id, definido_em desc);

-- ------------------------------------------------------------------ acesso
create function public.pode_aceder_empresa(empresa uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_staff() or (
    public.user_enabled((select auth.uid()))
    and exists (
      select 1 from public.account_access a
      join public.client_accounts ca on ca.id = a.account_id
      where a.user_id = (select auth.uid()) and a.business and a.active and ca.status = 'active')
    and exists (
      select 1 from public.company_users cu
      join public.companies c on c.id = cu.company_id
      where cu.company_id = empresa and cu.user_id = (select auth.uid()) and cu.active and c.active))
$$;

-- O fim do prazo dos documentos de um mês: o início do dia 11 do mês
-- seguinte, em Lisboa. Quem envia no dia 10 às 23h59 ainda está a tempo.
create function public.prazo_documentos(mes date) returns timestamptz
language sql stable set search_path = '' as $$
  select ((date_trunc('month', mes)::date + interval '1 month' + interval '10 days')::timestamp
          at time zone 'Europe/Lisbon')
$$;

create function public.mes_lisboa() returns date
language sql stable set search_path = '' as $$
  select date_trunc('month', (now() at time zone 'Europe/Lisbon'))::date
$$;

-- ---------------------------------------------------------------- atividade
create table public.empresa_atividade (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid,
  tipo text not null check (length(tipo) between 1 and 60),
  detalhe text check (detalhe is null or length(detalhe) <= 2000),
  ip text check (ip is null or length(ip) <= 100),
  agente text check (agente is null or length(agente) <= 400),
  criado_em timestamptz not null default now()
);
create index empresa_atividade_empresa on public.empresa_atividade(company_id, criado_em desc);

create function public.registar_empresa(empresa uuid, tipo text, detalhe text) returns void
language sql security definer set search_path = '' as $$
  insert into public.empresa_atividade(company_id, user_id, tipo, detalhe)
  values (empresa, auth.uid(), tipo, left(detalhe, 2000))
$$;

-- --------------------------------------------------------------- documentos
create table public.empresa_documentos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  categoria text not null check (categoria in ('vendas', 'compras', 'bancos', 'pessoal', 'outros')),
  nome text not null check (length(nome) between 1 and 220),
  caminho text not null unique,
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  tamanho bigint not null check (tamanho between 1 and 10485760),
  tamanho_original bigint check (tamanho_original is null or tamanho_original > 0),
  nota text check (nota is null or length(nota) <= 500),
  estado text not null default 'pendente' check (estado in ('pendente', 'recebido', 'visto', 'devolvido')),
  atrasado boolean not null default false,
  resposta text check (resposta is null or length(resposta) <= 1000),
  enviado_por uuid not null,
  criado_em timestamptz not null default now(),
  enviado_em timestamptz,
  revisto_em timestamptz,
  revisto_por uuid
);
create index empresa_documentos_mes on public.empresa_documentos(company_id, mes desc, criado_em desc);

create table public.empresa_meses (
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  completo_em timestamptz,
  completo_por uuid,
  conferido_em timestamptz,
  conferido_por uuid,
  nota text check (nota is null or length(nota) <= 1000),
  primary key (company_id, mes)
);

-- ---------------------------------------------------------------- mensagens
create table public.empresa_mensagens (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  autor_id uuid not null,
  do_gabinete boolean not null,
  corpo text not null check (length(btrim(corpo)) between 1 and 5000),
  criado_em timestamptz not null default now(),
  lida_em timestamptz
);
create index empresa_mensagens_empresa on public.empresa_mensagens(company_id, criado_em desc);

-- ------------------------------------------------------------------- prazos
create table public.empresa_prazos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  titulo text not null check (length(btrim(titulo)) between 1 and 200),
  descricao text check (descricao is null or length(descricao) <= 1000),
  data date not null,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_prazos_data on public.empresa_prazos(data);

-- ---------------------------------------------------------------- cache Cegid
create table public.empresa_cegid_cache (
  company_id uuid not null references public.companies(id) on delete cascade,
  chave text not null check (length(chave) <= 300),
  dados jsonb not null,
  obtido_em timestamptz not null default now(),
  primary key (company_id, chave)
);

-- ----------------------------------------------------------- permissões e RLS
alter table public.empresa_cortes enable row level security;
alter table public.empresa_atividade enable row level security;
alter table public.empresa_documentos enable row level security;
alter table public.empresa_meses enable row level security;
alter table public.empresa_mensagens enable row level security;
alter table public.empresa_prazos enable row level security;
alter table public.empresa_cegid_cache enable row level security;

revoke all on public.empresa_cortes, public.empresa_atividade, public.empresa_documentos, public.empresa_meses,
  public.empresa_mensagens, public.empresa_prazos, public.empresa_cegid_cache from anon, authenticated;
grant select on public.empresa_cortes, public.empresa_atividade, public.empresa_documentos, public.empresa_meses,
  public.empresa_mensagens, public.empresa_prazos to authenticated;
grant insert, delete on public.empresa_prazos to authenticated;
grant select, insert on public.empresa_atividade to service_role;
grant select, insert, update, delete on public.empresa_cegid_cache to service_role;

create policy empresa_cortes_ler on public.empresa_cortes for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_atividade_ler on public.empresa_atividade for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_documentos_ler on public.empresa_documentos for select to authenticated
  using (public.pode_aceder_empresa(company_id)
         and (estado <> 'pendente' or enviado_por = (select auth.uid())));
create policy empresa_meses_ler on public.empresa_meses for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_mensagens_ler on public.empresa_mensagens for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_prazos_ler on public.empresa_prazos for select to authenticated
  using ((select public.is_staff())
         or (company_id is null and exists (
               select 1 from public.company_users cu
               where cu.user_id = (select auth.uid()) and cu.active and public.pode_aceder_empresa(cu.company_id)))
         or (company_id is not null and public.pode_aceder_empresa(company_id)));
create policy empresa_prazos_criar on public.empresa_prazos for insert to authenticated
  with check ((select public.is_staff()) and criado_por = (select auth.uid()));
create policy empresa_prazos_apagar on public.empresa_prazos for delete to authenticated
  using ((select public.is_staff()));

-- ---------------------------------------------------------------- Storage
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('empresas-documentos', 'empresas-documentos', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy empresas_ficheiro_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and public.pode_aceder_empresa(d.company_id)
      and (d.estado <> 'pendente' or d.enviado_por = (select auth.uid()))));
create policy empresas_ficheiro_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and d.estado = 'pendente' and d.enviado_por = (select auth.uid())
      and public.pode_aceder_empresa(d.company_id)));
create policy empresas_ficheiro_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and d.estado in ('pendente', 'recebido')
      and (d.enviado_por = (select auth.uid()) or (select public.is_staff()))
      and public.pode_aceder_empresa(d.company_id)));

-- ---------------------------------------------------------------- funções

create function public.definir_data_corte(empresa uuid, corte date, nota text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then
    raise exception 'Apenas o contabilista define a data de corte' using errcode = '42501';
  end if;
  if corte is not null and corte > (now() at time zone 'Europe/Lisbon')::date then
    raise exception 'A data de corte não pode ser futura' using errcode = '22023';
  end if;
  if corte is not null and corte < date '2000-01-01' then
    raise exception 'Data de corte inválida' using errcode = '22023';
  end if;
  update public.companies
     set data_corte = corte, data_corte_em = now(), data_corte_por = auth.uid()
   where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_cortes(company_id, data_corte, nota, definido_por)
  values (empresa, corte, nullif(left(btrim(coalesce(nota, '')), 500), ''), auth.uid());
  delete from public.empresa_cegid_cache where company_id = empresa;
  perform public.registar_empresa(empresa, 'data_corte',
    case when corte is null then 'Data de corte retirada'
         else 'Data de corte: ' || to_char(corte, 'DD/MM/YYYY') end);
end $$;

create function public.preparar_documento_empresa(
  empresa uuid, mes date, categoria text, nome text, mime text,
  tamanho bigint, tamanho_original bigint default null, nota text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  eu uuid := auth.uid();
  atual date := public.mes_lisboa();
  novo uuid := gen_random_uuid();
  caminho text;
begin
  if eu is null or not public.user_enabled(eu) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > atual or mes < (atual - interval '24 months')::date then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'
        and d.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  caminho := empresa::text || '/' || to_char(mes, 'YYYY-MM') || '/' || novo::text || '.' ||
    case mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg'
              when 'image/png' then 'png' when 'image/webp' then 'webp' else 'bin' end;
  insert into public.empresa_documentos(id, company_id, mes, categoria, nome, caminho, mime, tamanho,
                                        tamanho_original, nota, enviado_por)
  values (novo, empresa, mes, categoria, left(btrim(nome), 220), caminho, mime, tamanho, tamanho_original,
          nullif(left(btrim(coalesce(nota, '')), 500), ''), eu);
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create function public.concluir_documento_empresa(documento uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos; prazo timestamptz;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(d.company_id) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  prazo := public.prazo_documentos(d.mes);
  if d.estado <> 'pendente' then
    return jsonb_build_object('id', d.id, 'atrasado', d.atrasado, 'prazo', prazo, 'mes', d.mes);
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho) then
    raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
  end if;
  update public.empresa_documentos
     set estado = 'recebido', enviado_em = now(), atrasado = now() >= prazo
   where id = d.id;
  perform public.registar_empresa(d.company_id, case when now() >= prazo then 'documento_atrasado' else 'documento' end,
    'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') ||
    case when now() >= prazo then ' (fora do prazo)' else '' end);
  return jsonb_build_object('id', d.id, 'atrasado', now() >= prazo, 'prazo', prazo, 'mes', d.mes);
end $$;

create function public.eliminar_documento_empresa(documento uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or not public.pode_aceder_empresa(d.company_id)
     or (d.enviado_por is distinct from auth.uid() and not public.is_staff()) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  if d.estado not in ('pendente', 'recebido') then
    raise exception 'Documento já revisto pelo contabilista' using errcode = '22023';
  end if;
  if d.estado = 'recebido' and exists (
       select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho) then
    raise exception 'Apague primeiro o ficheiro' using errcode = '22023';
  end if;
  delete from public.empresa_documentos where id = d.id;
  if d.estado = 'recebido' then
    perform public.registar_empresa(d.company_id, 'documento_eliminado',
      'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') || ' eliminado');
  end if;
end $$;

create function public.rever_documento_empresa(documento uuid, novo_estado text, resposta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista revê documentos' using errcode = '42501'; end if;
  if novo_estado not in ('recebido', 'visto', 'devolvido') then raise exception 'Estado inválido' using errcode = '22023'; end if;
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.estado = 'pendente' then raise exception 'Documento indisponível' using errcode = '22023'; end if;
  update public.empresa_documentos
     set estado = novo_estado,
         resposta = nullif(left(btrim(coalesce(rever_documento_empresa.resposta, '')), 1000), ''),
         revisto_em = case when novo_estado = 'recebido' then null else now() end,
         revisto_por = case when novo_estado = 'recebido' then null else auth.uid() end
   where id = d.id;
  if novo_estado = 'devolvido' then
    perform public.registar_empresa(d.company_id, 'documento_devolvido',
      'Documento «' || d.nome || '» devolvido' || coalesce(': ' || nullif(btrim(rever_documento_empresa.resposta), ''), ''));
  end if;
end $$;

create function public.marcar_mes_completo(empresa uuid, mes date, completo boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > public.mes_lisboa() then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  insert into public.empresa_meses(company_id, mes, completo_em, completo_por)
  values (empresa, mes, case when completo then now() end, case when completo then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set completo_em = excluded.completo_em, completo_por = excluded.completo_por;
  perform public.registar_empresa(empresa, 'mes_completo',
    to_char(mes, 'MM/YYYY') || case when completo then ': documentação dada como completa' else ': reaberto para mais documentos' end);
end $$;

create function public.conferir_mes_empresa(empresa uuid, mes date, conferido boolean, nota text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista confere o mês' using errcode = '42501'; end if;
  if mes is null or mes <> date_trunc('month', mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  if not exists (select 1 from public.companies where id = empresa) then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_meses(company_id, mes, conferido_em, conferido_por, nota)
  values (empresa, mes, case when conferido then now() end, case when conferido then auth.uid() end,
          nullif(left(btrim(coalesce(nota, '')), 1000), ''))
  on conflict on constraint empresa_meses_pkey do update
    set conferido_em = excluded.conferido_em, conferido_por = excluded.conferido_por,
        nota = coalesce(excluded.nota, public.empresa_meses.nota);
  perform public.registar_empresa(empresa, 'mes_conferido',
    to_char(mes, 'MM/YYYY') || case when conferido then ': documentos conferidos pelo contabilista' else ': conferência anulada' end);
end $$;

create function public.enviar_mensagem_empresa(empresa uuid, corpo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare novo uuid;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if corpo is null or length(btrim(corpo)) not between 1 and 5000 then
    raise exception 'Mensagem vazia ou demasiado longa' using errcode = '22023';
  end if;
  insert into public.empresa_mensagens(company_id, autor_id, do_gabinete, corpo)
  values (empresa, auth.uid(), public.is_staff(), btrim(corpo)) returning id into novo;
  return novo;
end $$;

-- Marca como lidas as mensagens do outro lado. Devolve quantas.
create function public.ler_mensagens_empresa(empresa uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  update public.empresa_mensagens set lida_em = now()
   where company_id = empresa and lida_em is null and do_gabinete <> public.is_staff();
  get diagnostics n = row_count;
  return n;
end $$;

-- O contexto do portal, numa só ida: quem é, e que empresas vê.
create function public.portal_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare eu uuid := auth.uid(); staff boolean; perfil public.profiles; acesso record;
begin
  if eu is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into perfil from public.profiles where id = eu;
  staff := public.is_staff();
  select coalesce(bool_or(a.business and a.active and ca.status = 'active'), false) as empresas,
         coalesce(bool_or(a.irs and a.active and ca.status = 'active'), false) as irs
    into acesso
    from public.account_access a join public.client_accounts ca on ca.id = a.account_id
   where a.user_id = eu;
  return jsonb_build_object(
    'id', eu,
    'email', coalesce(perfil.email, (select email from auth.users where id = eu)),
    'nome', nullif(btrim(coalesce(perfil.full_name, '')), ''),
    'is_staff', staff,
    'ativo', public.user_enabled(eu),
    'acesso_empresas', staff or coalesce(acesso.empresas, false),
    'acesso_irs', coalesce(acesso.irs, false),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte,
               'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text))
             order by c.name)
        from public.companies c
       where c.active and public.pode_aceder_empresa(c.id)), '[]'::jsonb));
end $$;

-- A visão geral de uma empresa, numa só ida.
create function public.empresa_resumo(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.companies;
  staff boolean := public.is_staff();
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  -- O mês cujos documentos estão a ser pedidos agora: até dia 10, o anterior.
  em_curso date;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  select * into c from public.companies where id = empresa;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  return jsonb_build_object(
    'empresa', jsonb_build_object(
      'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'data_corte_em', c.data_corte_em,
      'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text)),
    'hoje', hoje,
    'mes_em_curso', em_curso,
    'meses', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'mes', m.mes,
               'prazo', public.prazo_documentos(m.mes),
               'documentos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado <> 'pendente'),
               'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.atrasado and d.estado <> 'pendente'),
               'devolvidos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado = 'devolvido'),
               'completo_em', em.completo_em,
               'conferido_em', em.conferido_em) order by m.mes desc), '[]'::jsonb)
        from (select (atual - make_interval(months => g))::date as mes from generate_series(0, 5) g) m
        left join public.empresa_meses em on em.company_id = empresa and em.mes = m.mes),
    'mensagens_por_ler', (
      select count(*) from public.empresa_mensagens m
       where m.company_id = empresa and m.lida_em is null and m.do_gabinete <> staff),
    'ultima_mensagem', (
      select jsonb_build_object('corpo', left(m.corpo, 280), 'em', m.criado_em, 'do_gabinete', m.do_gabinete)
        from public.empresa_mensagens m where m.company_id = empresa order by m.criado_em desc limit 1),
    'prazos', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'titulo', p.titulo, 'data', p.data,
                                                   'descricao', p.descricao, 'geral', p.company_id is null)
                                order by p.data), '[]'::jsonb)
        from (select * from public.empresa_prazos p
               where (p.company_id = empresa or p.company_id is null) and p.data >= hoje
               order by p.data limit 6) p),
    'atividade', (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'detalhe', a.detalhe, 'em', a.criado_em)
                                order by a.criado_em desc), '[]'::jsonb)
        from (select * from public.empresa_atividade a where a.company_id = empresa
               order by a.criado_em desc limit 8) a));
end $$;

-- A lista da gestão: o estado de cada empresa, numa só ida.
create function public.gestao_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  em_curso date;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  return jsonb_build_object(
    'mes_em_curso', em_curso,
    'prazo', public.prazo_documentos(em_curso),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'data_corte', c.data_corte,
        'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text),
        'documentos', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.estado <> 'pendente'),
        'por_ver', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.estado = 'recebido'),
        'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.atrasado and d.estado <> 'pendente'),
        'completo', (select em.completo_em is not null from public.empresa_meses em where em.company_id = c.id and em.mes = em_curso),
        'mensagens', (select count(*) from public.empresa_mensagens m where m.company_id = c.id and m.lida_em is null and not m.do_gabinete)))
        from public.companies c), '[]'::jsonb));
end $$;

-- ------------------------------------------------------- execute das funções
do $x$
declare f text;
begin
  foreach f in array array[
    'public.pode_aceder_empresa(uuid)', 'public.prazo_documentos(date)', 'public.mes_lisboa()',
    'public.definir_data_corte(uuid,date,text)', 'public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)',
    'public.concluir_documento_empresa(uuid)', 'public.eliminar_documento_empresa(uuid)',
    'public.rever_documento_empresa(uuid,text,text)', 'public.marcar_mes_completo(uuid,date,boolean)',
    'public.conferir_mes_empresa(uuid,date,boolean,text)', 'public.enviar_mensagem_empresa(uuid,text)',
    'public.ler_mensagens_empresa(uuid)', 'public.portal_empresas()', 'public.empresa_resumo(uuid)',
    'public.gestao_empresas()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;
-- O registo interno só é chamado pelas funções acima.
revoke all on function public.registar_empresa(uuid, text, text) from public, anon, authenticated;

-- Source: 202610300061_empresas_completo.sql
-- Portal Empresas, segunda volta.
--
-- 1. Definições da empresa (só o contabilista): mês de início do
--    acompanhamento (não há meses antes dele), meses bloqueados para envio e
--    meses fechados com a informação completa.
-- 2. Ficha da empresa (dados fiscais), editável pelo contabilista e pelo
--    cliente, com o histórico de cada alteração: quem, quando, de onde, o
--    valor antes e depois.
-- 3. Alertas do gabinete que aparecem no portal, com leitura por pessoa.
-- 4. Logótipo da empresa (WebP pequeno, Storage privado).
-- 5. Pessoal: comunicações de admissões, cessações, ausências e alterações,
--    tratadas pelo contabilista; e os recibos de vencimento de cada mês, um
--    PDF por mês.
-- 6. Impostos: períodos por tipo (IRC, IVA, IRS, Segurança Social, outros),
--    com guia, referência, valor e prazo; o cliente marca como pago e junta o
--    comprovativo.
-- 7. A cache do Cegid sai da base: passa para a cache de dados do Next, com
--    uma versão por empresa na chave. A tabela empresa_cegid_cache é apagada.
--
-- Funções novas: sem execute para public/anon; autorização dentro de cada uma.

-- ------------------------------------------------------------ empresa
alter table public.companies
  add column inicio date check (inicio is null or inicio = date_trunc('month', inicio)::date),
  add column logotipo_caminho text,
  add column logotipo_em timestamptz,
  add column cegid_versao integer not null default 0;

alter table public.empresa_meses
  add column bloqueado boolean not null default false,
  add column fechado_em timestamptz,
  add column fechado_por uuid;

-- O NIF português: nove algarismos e o dígito de controlo (módulo 11).
create function public.nif_valido(nif text) returns boolean
language sql immutable set search_path = '' as $$
  select case when coalesce(nif, '') !~ '^[1-9][0-9]{8}$' then false else (
    with d as (select substr(nif, i, 1)::int as v, i from generate_series(1, 9) i),
         s as (select sum(v * (10 - i)) as t from d where i <= 8)
    select case when 11 - (t % 11) >= 10 then 0 else 11 - (t % 11) end = (select v from d where i = 9) from s) end
$$;

-- ------------------------------------------------------------ ficha
create table public.empresa_fichas (
  company_id uuid primary key references public.companies(id) on delete cascade,
  forma_juridica text check (forma_juridica is null or length(forma_juridica) <= 100),
  cae text check (cae is null or cae ~ '^[0-9]{5}(\s*[,;]\s*[0-9]{5}){0,9}$'),
  regime_iva text check (regime_iva is null or regime_iva in ('mensal', 'trimestral', 'isento_53', 'outro')),
  regime_iva_outro text check (regime_iva_outro is null or length(regime_iva_outro) <= 200),
  tem_trabalhadores boolean not null default false,
  morada text check (morada is null or length(morada) <= 300),
  codigo_postal text check (codigo_postal is null or codigo_postal ~ '^[0-9]{4}-[0-9]{3}$'),
  localidade text check (localidade is null or length(localidade) <= 100),
  capital_social numeric(16, 2) check (capital_social is null or capital_social >= 0),
  representantes text check (representantes is null or length(representantes) <= 1000),
  niss text check (niss is null or niss ~ '^[0-9]{11}$'),
  iban text check (iban is null or iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'),
  email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  telefone text check (telefone is null or length(telefone) between 6 and 30),
  contacto_nome text check (contacto_nome is null or length(contacto_nome) <= 200),
  contacto_email text check (contacto_email is null or contacto_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contacto_telefone text check (contacto_telefone is null or length(contacto_telefone) between 6 and 30),
  atualizado_em timestamptz,
  atualizado_por uuid
);

create table public.empresa_ficha_historico (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  campo text not null,
  antes text,
  depois text,
  origem text not null check (origem in ('gestao', 'portal')),
  alterado_por uuid,
  alterado_em timestamptz not null default now()
);
create index empresa_ficha_historico_empresa on public.empresa_ficha_historico(company_id, alterado_em desc);

-- ------------------------------------------------------------ alertas
create table public.empresa_alertas (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade, -- nulo: todas as empresas
  titulo text not null check (length(btrim(titulo)) between 1 and 200),
  corpo text check (corpo is null or length(corpo) <= 2000),
  nivel text not null default 'info' check (nivel in ('info', 'aviso', 'urgente')),
  expira_em date,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_alertas_empresa on public.empresa_alertas(company_id, criado_em desc);
create table public.empresa_alertas_lidos (
  alerta_id uuid not null references public.empresa_alertas(id) on delete cascade,
  user_id uuid not null,
  lido_em timestamptz not null default now(),
  primary key (alerta_id, user_id)
);

-- ------------------------------------------------------------ pessoal
create table public.empresa_pessoal (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('admissao', 'cessacao', 'ausencia', 'alteracao')),
  trabalhador text not null check (length(btrim(trabalhador)) between 1 and 200),
  dados jsonb not null default '{}'::jsonb check (jsonb_typeof(dados) = 'object' and length(dados::text) <= 8000),
  estado text not null default 'novo' check (estado in ('novo', 'em_tratamento', 'tratado', 'devolvido')),
  resposta text check (resposta is null or length(resposta) <= 1000),
  criado_por uuid not null,
  criado_em timestamptz not null default now(),
  tratado_em timestamptz,
  tratado_por uuid
);
create index empresa_pessoal_empresa on public.empresa_pessoal(company_id, criado_em desc);

create table public.empresa_recibos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  publicado_em timestamptz,
  publicado_por uuid,
  descarregado_em timestamptz,
  unique (company_id, mes)
);

-- ------------------------------------------------------------ impostos
create table public.empresa_impostos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('IRC', 'IVA', 'IRS', 'SS', 'OUTROS')),
  periodo text not null check (length(btrim(periodo)) between 1 and 20),
  descricao text check (descricao is null or length(descricao) <= 300),
  referencia text check (referencia is null or length(referencia) <= 200),
  valor numeric(14, 2) check (valor is null or valor >= 0),
  prazo date,
  estado text not null default 'por_pagar' check (estado in ('por_pagar', 'pago')),
  pago_em timestamptz,
  pago_por uuid,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_impostos_empresa on public.empresa_impostos(company_id, prazo);

-- ------------------------------------------------------------ ficheiros
-- Um só registo para os ficheiros destas secções: documentos do pessoal,
-- recibos de vencimento, guias de impostos e comprovativos de pagamento.
create table public.empresa_ficheiros (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contexto text not null check (contexto in ('pessoal', 'recibos', 'guia', 'comprovativo')),
  ref_id uuid not null,
  nome text not null check (length(nome) between 1 and 220),
  caminho text not null unique,
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  tamanho bigint not null check (tamanho between 1 and 10485760),
  estado text not null default 'pendente' check (estado in ('pendente', 'carregado')),
  enviado_por uuid not null,
  criado_em timestamptz not null default now(),
  carregado_em timestamptz
);
create index empresa_ficheiros_ref on public.empresa_ficheiros(ref_id);

-- ----------------------------------------------------------- RLS e permissões
alter table public.empresa_fichas enable row level security;
alter table public.empresa_ficha_historico enable row level security;
alter table public.empresa_alertas enable row level security;
alter table public.empresa_alertas_lidos enable row level security;
alter table public.empresa_pessoal enable row level security;
alter table public.empresa_recibos enable row level security;
alter table public.empresa_impostos enable row level security;
alter table public.empresa_ficheiros enable row level security;

revoke all on public.empresa_fichas, public.empresa_ficha_historico, public.empresa_alertas, public.empresa_alertas_lidos,
  public.empresa_pessoal, public.empresa_recibos, public.empresa_impostos, public.empresa_ficheiros from anon, authenticated;
grant select on public.empresa_fichas, public.empresa_ficha_historico, public.empresa_alertas, public.empresa_alertas_lidos,
  public.empresa_pessoal, public.empresa_recibos, public.empresa_impostos, public.empresa_ficheiros to authenticated;
grant insert, delete on public.empresa_alertas to authenticated;

create policy empresa_fichas_ler on public.empresa_fichas for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_ficha_historico_ler on public.empresa_ficha_historico for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_alertas_ler on public.empresa_alertas for select to authenticated
  using ((select public.is_staff())
         or (company_id is null and exists (
               select 1 from public.company_users cu
               where cu.user_id = (select auth.uid()) and cu.active and public.pode_aceder_empresa(cu.company_id)))
         or (company_id is not null and public.pode_aceder_empresa(company_id)));
create policy empresa_alertas_criar on public.empresa_alertas for insert to authenticated
  with check ((select public.is_staff()) and criado_por = (select auth.uid()));
create policy empresa_alertas_apagar on public.empresa_alertas for delete to authenticated
  using ((select public.is_staff()));
create policy empresa_alertas_lidos_ler on public.empresa_alertas_lidos for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_staff()));
create policy empresa_pessoal_ler on public.empresa_pessoal for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_recibos_ler on public.empresa_recibos for select to authenticated
  using (public.pode_aceder_empresa(company_id) and (publicado_em is not null or (select public.is_staff())));
create policy empresa_impostos_ler on public.empresa_impostos for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_ficheiros_ler on public.empresa_ficheiros for select to authenticated
  using (public.pode_aceder_empresa(company_id) and (estado = 'carregado' or enviado_por = (select auth.uid())));

-- ------------------------------------------------------------ Storage
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('empresas-ficheiros', 'empresas-ficheiros', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']),
       ('empresas-logotipos', 'empresas-logotipos', false, 524288, array['image/webp', 'image/png'])
on conflict (id) do nothing;

create policy empresas_ficheiros_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and public.pode_aceder_empresa(f.company_id)
      and (f.estado = 'carregado' or f.enviado_por = (select auth.uid()))));
create policy empresas_ficheiros_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and f.estado = 'pendente' and f.enviado_por = (select auth.uid())
      and public.pode_aceder_empresa(f.company_id)));
create policy empresas_ficheiros_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and public.pode_aceder_empresa(f.company_id)
      and (f.enviado_por = (select auth.uid()) or (select public.is_staff()))));

-- O logótipo: <empresa>/logotipo-<número>.webp, de quem pode ver a empresa.
create function public.logotipo_da_empresa(caminho text) returns uuid
language sql immutable set search_path = '' as $$
  select case when caminho ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/logotipo-[0-9]{1,20}\.(webp|png)$'
              then split_part(caminho, '/', 1)::uuid end
$$;
create policy empresas_logotipo_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));
create policy empresas_logotipo_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));
create policy empresas_logotipo_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));

-- ------------------------------------------------------------ funções

-- Definições: só o contabilista.
create function public.definir_inicio_empresa(empresa uuid, p_inicio date) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista define o início' using errcode = '42501'; end if;
  update public.companies set inicio = date_trunc('month', p_inicio)::date where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  perform public.registar_empresa(empresa, 'definicoes',
    case when p_inicio is null then 'Início do acompanhamento retirado'
         else 'Início do acompanhamento: ' || to_char(date_trunc('month', p_inicio), 'MM/YYYY') end);
end $$;

create function public.definir_mes_empresa(empresa uuid, p_mes date, p_bloqueado boolean, p_fechado boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista bloqueia ou fecha meses' using errcode = '42501'; end if;
  if p_mes is null or p_mes <> date_trunc('month', p_mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  if not exists (select 1 from public.companies where id = empresa) then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_meses(company_id, mes, bloqueado, fechado_em, fechado_por)
  values (empresa, p_mes, coalesce(p_bloqueado, false), case when p_fechado then now() end, case when p_fechado then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set bloqueado = excluded.bloqueado,
        fechado_em = case when p_fechado then coalesce(public.empresa_meses.fechado_em, now()) end,
        fechado_por = case when p_fechado then coalesce(public.empresa_meses.fechado_por, auth.uid()) end;
  perform public.registar_empresa(empresa, 'definicoes', to_char(p_mes, 'MM/YYYY') || ': ' ||
    case when p_fechado then 'informação completa (mês fechado)' when p_bloqueado then 'envio de documentos bloqueado' else 'aberto para envio' end);
end $$;

-- A versão da ligação ao Cegid de uma empresa: entra na chave da cache do
-- portal. Subir a versão é deitar a cache fora.
create function public.renovar_cegid_empresa(empresa uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  update public.companies set cegid_versao = cegid_versao + 1 where id = empresa returning cegid_versao into v;
  if v is null then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  return v;
end $$;

-- A ficha: os dois lados escrevem, e cada campo alterado fica no histórico.
create function public.guardar_ficha_empresa(empresa uuid, dados jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  staff boolean := public.is_staff();
  c public.companies;
  f public.empresa_fichas;
  antes jsonb;
  depois jsonb;
  k text;
  permitidos text[] := array['nome', 'nif', 'forma_juridica', 'cae', 'regime_iva', 'regime_iva_outro', 'tem_trabalhadores',
    'morada', 'codigo_postal', 'localidade', 'capital_social', 'representantes', 'niss', 'iban', 'email', 'telefone',
    'contacto_nome', 'contacto_email', 'contacto_telefone'];
  alterados text[] := '{}';
  v text;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if dados is null or jsonb_typeof(dados) <> 'object' then raise exception 'Dados inválidos' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(dados) loop
    if not k = any(permitidos) then raise exception 'Campo desconhecido: %', k using errcode = '22023'; end if;
  end loop;

  select * into c from public.companies where id = empresa for update;
  insert into public.empresa_fichas(company_id) values (empresa) on conflict do nothing;
  select * into f from public.empresa_fichas where company_id = empresa for update;
  antes := to_jsonb(f) || jsonb_build_object('nome', c.name, 'nif', c.nif);

  -- Normaliza: texto aparado, vazio é nulo; IBAN sem espaços e em maiúsculas.
  depois := antes;
  for k in select jsonb_object_keys(dados) loop
    if k = 'tem_trabalhadores' then
      depois := jsonb_set(depois, array[k], to_jsonb(coalesce((dados->>k)::boolean, false)));
    elsif k = 'capital_social' then
      depois := jsonb_set(depois, array[k], coalesce(to_jsonb(nullif(btrim(dados->>k), '')::numeric(16, 2)), 'null'::jsonb));
    else
      v := nullif(btrim(coalesce(dados->>k, '')), '');
      if k = 'iban' and v is not null then v := upper(replace(v, ' ', '')); end if;
      depois := jsonb_set(depois, array[k], coalesce(to_jsonb(v), 'null'::jsonb));
    end if;
  end loop;

  if depois->>'nome' is null or length(depois->>'nome') > 200 then raise exception 'Indique o nome da empresa' using errcode = '22023'; end if;
  if (depois->>'nif') is distinct from c.nif and not coalesce(public.nif_valido(depois->>'nif'), false) then
    raise exception 'NIF inválido' using errcode = '22023';
  end if;
  if (depois->>'nif') is distinct from c.nif and exists (select 1 from public.companies where nif = depois->>'nif' and id <> empresa) then
    raise exception 'Já existe uma empresa com este NIF' using errcode = '23505';
  end if;

  update public.companies set name = depois->>'nome', nif = depois->>'nif' where id = empresa;
  update public.empresa_fichas set
    forma_juridica = depois->>'forma_juridica', cae = depois->>'cae', regime_iva = depois->>'regime_iva',
    regime_iva_outro = depois->>'regime_iva_outro', tem_trabalhadores = (depois->>'tem_trabalhadores')::boolean,
    morada = depois->>'morada', codigo_postal = depois->>'codigo_postal', localidade = depois->>'localidade',
    capital_social = (depois->>'capital_social')::numeric(16, 2), representantes = depois->>'representantes',
    niss = depois->>'niss', iban = depois->>'iban', email = depois->>'email', telefone = depois->>'telefone',
    contacto_nome = depois->>'contacto_nome', contacto_email = depois->>'contacto_email',
    contacto_telefone = depois->>'contacto_telefone', atualizado_em = now(), atualizado_por = auth.uid()
  where company_id = empresa;

  foreach k in array permitidos loop
    if (antes->>k) is distinct from (depois->>k) then
      alterados := alterados || k;
      insert into public.empresa_ficha_historico(company_id, campo, antes, depois, origem, alterado_por)
      values (empresa, k, antes->>k, depois->>k, case when staff then 'gestao' else 'portal' end, auth.uid());
    end if;
  end loop;
  if array_length(alterados, 1) > 0 then
    perform public.registar_empresa(empresa, 'ficha', 'Dados da empresa alterados: ' || array_to_string(alterados, ', '));
  end if;
  return coalesce(array_length(alterados, 1), 0);
end $$;

create function public.ler_alerta_empresa(alerta uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.empresa_alertas;
begin
  select * into a from public.empresa_alertas where id = alerta;
  if not found or auth.uid() is null then raise exception 'Alerta indisponível' using errcode = '42501'; end if;
  if a.company_id is not null and not public.pode_aceder_empresa(a.company_id) then
    raise exception 'Alerta indisponível' using errcode = '42501';
  end if;
  if a.company_id is null and not public.is_staff() and not exists (
       select 1 from public.company_users cu where cu.user_id = auth.uid() and cu.active and public.pode_aceder_empresa(cu.company_id)) then
    raise exception 'Alerta indisponível' using errcode = '42501';
  end if;
  insert into public.empresa_alertas_lidos(alerta_id, user_id) values (alerta, auth.uid()) on conflict do nothing;
end $$;

create function public.definir_logotipo_empresa(empresa uuid, caminho text) returns text
language plpgsql security definer set search_path = '' as $$
declare anterior text;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if caminho is not null and (public.logotipo_da_empresa(caminho) is distinct from empresa
     or not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-logotipos' and o.name = caminho)) then
    raise exception 'Logótipo inválido' using errcode = '22023';
  end if;
  select logotipo_caminho into anterior from public.companies where id = empresa for update;
  update public.companies set logotipo_caminho = caminho, logotipo_em = case when caminho is null then null else now() end where id = empresa;
  perform public.registar_empresa(empresa, 'logotipo', case when caminho is null then 'Logótipo retirado' else 'Logótipo atualizado' end);
  return anterior;
end $$;

-- Pessoal.
create function public.comunicar_pessoal(empresa uuid, p_tipo text, p_trabalhador text, p_dados jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare novo uuid;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if not coalesce((select tem_trabalhadores from public.empresa_fichas where company_id = empresa), false) then
    raise exception 'Esta empresa não tem trabalhadores registados' using errcode = '22023';
  end if;
  insert into public.empresa_pessoal(company_id, tipo, trabalhador, dados, criado_por)
  values (empresa, p_tipo, btrim(p_trabalhador), coalesce(p_dados, '{}'::jsonb), auth.uid()) returning id into novo;
  perform public.registar_empresa(empresa, 'pessoal',
    case p_tipo when 'admissao' then 'Admissão comunicada: ' when 'cessacao' then 'Cessação comunicada: '
                when 'ausencia' then 'Ausência comunicada: ' else 'Alteração comunicada: ' end || btrim(p_trabalhador));
  return novo;
end $$;

create function public.tratar_pessoal(pedido uuid, p_estado text, p_resposta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.empresa_pessoal;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista trata o pessoal' using errcode = '42501'; end if;
  if p_estado not in ('novo', 'em_tratamento', 'tratado', 'devolvido') then raise exception 'Estado inválido' using errcode = '22023'; end if;
  update public.empresa_pessoal
     set estado = p_estado, resposta = nullif(left(btrim(coalesce(p_resposta, '')), 1000), ''),
         tratado_em = case when p_estado in ('tratado', 'devolvido') then now() end,
         tratado_por = case when p_estado in ('tratado', 'devolvido') then auth.uid() end
   where id = pedido returning * into p;
  if p.id is null then raise exception 'Pedido desconhecido' using errcode = '22023'; end if;
  perform public.registar_empresa(p.company_id, 'pessoal',
    p.trabalhador || ': ' || case p_estado when 'tratado' then 'tratado pelo contabilista' when 'devolvido' then 'devolvido'
                                            when 'em_tratamento' then 'em tratamento' else 'reaberto' end);
end $$;

create function public.preparar_recibos_mes(empresa uuid, p_mes date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista publica recibos' using errcode = '42501'; end if;
  if p_mes is null or p_mes <> date_trunc('month', p_mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  insert into public.empresa_recibos(company_id, mes) values (empresa, p_mes)
  on conflict (company_id, mes) do update set mes = excluded.mes returning id into r;
  return r;
end $$;

-- Impostos.
create function public.guardar_imposto(p_id uuid, empresa uuid, p_tipo text, p_periodo text, p_descricao text,
  p_referencia text, p_valor numeric, p_prazo date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista publica impostos' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empresa_impostos(company_id, tipo, periodo, descricao, referencia, valor, prazo, criado_por)
    values (empresa, p_tipo, btrim(p_periodo), nullif(btrim(coalesce(p_descricao, '')), ''), nullif(btrim(coalesce(p_referencia, '')), ''),
            p_valor, p_prazo, auth.uid()) returning id into r;
    perform public.registar_empresa(empresa, 'imposto', p_tipo || ' ' || btrim(p_periodo) || ' publicado'
      || coalesce(' · prazo ' || to_char(p_prazo, 'DD/MM/YYYY'), ''));
  else
    update public.empresa_impostos
       set tipo = p_tipo, periodo = btrim(p_periodo), descricao = nullif(btrim(coalesce(p_descricao, '')), ''),
           referencia = nullif(btrim(coalesce(p_referencia, '')), ''), valor = p_valor, prazo = p_prazo
     where id = p_id and company_id = empresa returning id into r;
    if r is null then raise exception 'Imposto desconhecido' using errcode = '22023'; end if;
  end if;
  return r;
end $$;

create function public.apagar_imposto(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.empresa_impostos;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  delete from public.empresa_impostos where id = p_id returning * into i;
  if i.id is null then raise exception 'Imposto desconhecido' using errcode = '22023'; end if;
  delete from public.empresa_ficheiros where ref_id = p_id and contexto in ('guia', 'comprovativo');
  perform public.registar_empresa(i.company_id, 'imposto', i.tipo || ' ' || i.periodo || ' apagado');
end $$;

create function public.marcar_imposto_pago(p_id uuid, pago boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.empresa_impostos;
begin
  select * into i from public.empresa_impostos where id = p_id for update;
  if not found or auth.uid() is null or not public.pode_aceder_empresa(i.company_id) then
    raise exception 'Imposto indisponível' using errcode = '42501';
  end if;
  update public.empresa_impostos
     set estado = case when pago then 'pago' else 'por_pagar' end,
         pago_em = case when pago then coalesce(pago_em, now()) end,
         pago_por = case when pago then coalesce(pago_por, auth.uid()) end
   where id = p_id;
  perform public.registar_empresa(i.company_id, 'imposto',
    i.tipo || ' ' || i.periodo || case when pago then ' marcado como pago' else ' marcado como por pagar' end);
end $$;

-- Ficheiros: o mesmo circuito dos documentos do mês (pendente → Storage →
-- carregado), com quem pode o quê decidido pelo contexto.
create function public.preparar_ficheiro_empresa(empresa uuid, p_contexto text, p_ref uuid, p_nome text, p_mime text, p_tamanho bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  staff boolean := public.is_staff();
  novo uuid := gen_random_uuid();
  caminho text;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if p_contexto in ('recibos', 'guia') and not staff then
    raise exception 'Apenas o contabilista publica este ficheiro' using errcode = '42501';
  end if;
  if (p_contexto = 'pessoal' and not exists (select 1 from public.empresa_pessoal where id = p_ref and company_id = empresa))
     or (p_contexto = 'recibos' and not exists (select 1 from public.empresa_recibos where id = p_ref and company_id = empresa))
     or (p_contexto in ('guia', 'comprovativo') and not exists (select 1 from public.empresa_impostos where id = p_ref and company_id = empresa))
     or p_contexto not in ('pessoal', 'recibos', 'guia', 'comprovativo') then
    raise exception 'Referência inválida' using errcode = '22023';
  end if;
  caminho := empresa::text || '/' || p_contexto || '/' || p_ref::text || '/' || novo::text || '.' ||
    case p_mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' else 'bin' end;
  insert into public.empresa_ficheiros(id, company_id, contexto, ref_id, nome, caminho, mime, tamanho, enviado_por)
  values (novo, empresa, p_contexto, p_ref, left(btrim(p_nome), 220), caminho, p_mime, p_tamanho, auth.uid());
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create function public.concluir_ficheiro_empresa(ficheiro uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or f.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(f.company_id) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if f.estado = 'pendente' then
    if not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho) then
      raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
    end if;
    update public.empresa_ficheiros set estado = 'carregado', carregado_em = now() where id = f.id;
    if f.contexto = 'recibos' then
      update public.empresa_recibos set publicado_em = now(), publicado_por = auth.uid() where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'recibos', 'Recibos de vencimento publicados');
    elsif f.contexto = 'comprovativo' then
      update public.empresa_impostos set estado = 'pago', pago_em = coalesce(pago_em, now()), pago_por = coalesce(pago_por, auth.uid())
       where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'imposto', 'Comprovativo de pagamento enviado: ' || f.nome);
    elsif f.contexto = 'guia' then
      perform public.registar_empresa(f.company_id, 'imposto', 'Guia de pagamento publicada: ' || f.nome);
    end if;
  end if;
  return jsonb_build_object('id', f.id, 'contexto', f.contexto, 'ref', f.ref_id);
end $$;

create function public.apagar_ficheiro_empresa(ficheiro uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or not public.pode_aceder_empresa(f.company_id)
     or (f.enviado_por is distinct from auth.uid() and not public.is_staff()) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho) then
    raise exception 'Apague primeiro o ficheiro' using errcode = '22023';
  end if;
  delete from public.empresa_ficheiros where id = f.id;
end $$;

create function public.registar_descarga_empresa(ficheiro uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro;
  if not found or not public.pode_aceder_empresa(f.company_id) then raise exception 'Ficheiro indisponível' using errcode = '42501'; end if;
  if public.is_staff() then return; end if;
  if f.contexto = 'recibos' then
    update public.empresa_recibos set descarregado_em = coalesce(descarregado_em, now()) where id = f.ref_id;
  end if;
  perform public.registar_empresa(f.company_id, 'descarga', 'Descarregou «' || f.nome || '»');
end $$;

-- ------------------------------------------------ regras novas nas antigas

-- Envio de documentos: nada antes do início, nada em meses bloqueados ou
-- fechados (o contabilista pode sempre).
create or replace function public.preparar_documento_empresa(
  empresa uuid, mes date, categoria text, nome text, mime text,
  tamanho bigint, tamanho_original bigint default null, nota text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  eu uuid := auth.uid();
  atual date := public.mes_lisboa();
  novo uuid := gen_random_uuid();
  caminho text;
  inicio_empresa date;
  m public.empresa_meses;
begin
  if eu is null or not public.user_enabled(eu) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > atual or mes < (atual - interval '24 months')::date then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  select inicio into inicio_empresa from public.companies where id = empresa;
  if inicio_empresa is not null and mes < inicio_empresa then
    raise exception 'Mês anterior ao início do acompanhamento' using errcode = '22023';
  end if;
  select * into m from public.empresa_meses em where em.company_id = empresa and em.mes = preparar_documento_empresa.mes;
  if not public.is_staff() and (m.bloqueado or m.fechado_em is not null) then
    raise exception 'Mês fechado para envio' using errcode = '22023';
  end if;
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'
        and d.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  caminho := empresa::text || '/' || to_char(mes, 'YYYY-MM') || '/' || novo::text || '.' ||
    case mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg'
              when 'image/png' then 'png' when 'image/webp' then 'webp' else 'bin' end;
  insert into public.empresa_documentos(id, company_id, mes, categoria, nome, caminho, mime, tamanho,
                                        tamanho_original, nota, enviado_por)
  values (novo, empresa, mes, categoria, left(btrim(nome), 220), caminho, mime, tamanho, tamanho_original,
          nullif(left(btrim(coalesce(nota, '')), 500), ''), eu);
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create or replace function public.marcar_mes_completo(empresa uuid, mes date, completo boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > public.mes_lisboa() then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  if not public.is_staff() and exists (select 1 from public.empresa_meses em
       where em.company_id = empresa and em.mes = marcar_mes_completo.mes and em.fechado_em is not null) then
    raise exception 'Mês fechado pelo contabilista' using errcode = '22023';
  end if;
  insert into public.empresa_meses(company_id, mes, completo_em, completo_por)
  values (empresa, mes, case when completo then now() end, case when completo then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set completo_em = excluded.completo_em, completo_por = excluded.completo_por;
  perform public.registar_empresa(empresa, 'mes_completo',
    to_char(mes, 'MM/YYYY') || case when completo then ': documentação dada como completa' else ': reaberto para mais documentos' end);
end $$;

-- A data de corte sobe a versão do Cegid em vez de apagar a cache.
create or replace function public.definir_data_corte(empresa uuid, corte date, nota text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then
    raise exception 'Apenas o contabilista define a data de corte' using errcode = '42501';
  end if;
  if corte is not null and corte > (now() at time zone 'Europe/Lisbon')::date then
    raise exception 'A data de corte não pode ser futura' using errcode = '22023';
  end if;
  if corte is not null and corte < date '2000-01-01' then
    raise exception 'Data de corte inválida' using errcode = '22023';
  end if;
  update public.companies
     set data_corte = corte, data_corte_em = now(), data_corte_por = auth.uid(), cegid_versao = cegid_versao + 1
   where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_cortes(company_id, data_corte, nota, definido_por)
  values (empresa, corte, nullif(left(btrim(coalesce(nota, '')), 500), ''), auth.uid());
  perform public.registar_empresa(empresa, 'data_corte',
    case when corte is null then 'Data de corte retirada'
         else 'Data de corte: ' || to_char(corte, 'DD/MM/YYYY') end);
end $$;

drop table public.empresa_cegid_cache;

-- O contexto do portal: mais o logótipo, a versão do Cegid e o pessoal.
create or replace function public.portal_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare eu uuid := auth.uid(); staff boolean; perfil public.profiles; acesso record;
begin
  if eu is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into perfil from public.profiles where id = eu;
  staff := public.is_staff();
  select coalesce(bool_or(a.business and a.active and ca.status = 'active'), false) as empresas,
         coalesce(bool_or(a.irs and a.active and ca.status = 'active'), false) as irs
    into acesso
    from public.account_access a join public.client_accounts ca on ca.id = a.account_id
   where a.user_id = eu;
  return jsonb_build_object(
    'id', eu,
    'email', coalesce(perfil.email, (select email from auth.users where id = eu)),
    'nome', nullif(btrim(coalesce(perfil.full_name, '')), ''),
    'is_staff', staff,
    'ativo', public.user_enabled(eu),
    'acesso_empresas', staff or coalesce(acesso.empresas, false),
    'acesso_irs', coalesce(acesso.irs, false),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'inicio', c.inicio,
               'logotipo', c.logotipo_caminho, 'logotipo_em', c.logotipo_em, 'cegid_versao', c.cegid_versao,
               'tem_trabalhadores', coalesce((select f.tem_trabalhadores from public.empresa_fichas f where f.company_id = c.id), false),
               'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text))
             order by c.name)
        from public.companies c
       where c.active and public.pode_aceder_empresa(c.id)), '[]'::jsonb));
end $$;

-- A visão geral: meses só a partir do início, com bloqueio e fecho, e o que
-- há para pagar.
create or replace function public.empresa_resumo(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.companies;
  staff boolean := public.is_staff();
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  em_curso date;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  select * into c from public.companies where id = empresa;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  if c.inicio is not null and em_curso < c.inicio then em_curso := c.inicio; end if;
  return jsonb_build_object(
    'empresa', jsonb_build_object(
      'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'data_corte_em', c.data_corte_em, 'inicio', c.inicio,
      'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text)),
    'hoje', hoje,
    'mes_em_curso', em_curso,
    'meses', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'mes', m.mes,
               'prazo', public.prazo_documentos(m.mes),
               'documentos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado <> 'pendente'),
               'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.atrasado and d.estado <> 'pendente'),
               'devolvidos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado = 'devolvido'),
               'completo_em', em.completo_em,
               'conferido_em', em.conferido_em,
               'bloqueado', coalesce(em.bloqueado, false),
               'fechado_em', em.fechado_em) order by m.mes desc), '[]'::jsonb)
        from (select (atual - make_interval(months => g))::date as mes from generate_series(0, 5) g) m
        left join public.empresa_meses em on em.company_id = empresa and em.mes = m.mes
       where c.inicio is null or m.mes >= c.inicio),
    'mensagens_por_ler', (
      select count(*) from public.empresa_mensagens m
       where m.company_id = empresa and m.lida_em is null and m.do_gabinete <> staff),
    'ultima_mensagem', (
      select jsonb_build_object('corpo', left(m.corpo, 280), 'em', m.criado_em, 'do_gabinete', m.do_gabinete)
        from public.empresa_mensagens m where m.company_id = empresa order by m.criado_em desc limit 1),
    'prazos', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'titulo', p.titulo, 'data', p.data,
                                                   'descricao', p.descricao, 'geral', p.company_id is null)
                                order by p.data), '[]'::jsonb)
        from (select * from public.empresa_prazos p
               where (p.company_id = empresa or p.company_id is null) and p.data >= hoje
               order by p.data limit 6) p),
    'impostos', (
      select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'tipo', i.tipo, 'periodo', i.periodo, 'valor', i.valor,
                                                   'prazo', i.prazo, 'atrasado', i.prazo < hoje) order by i.prazo nulls last), '[]'::jsonb)
        from (select * from public.empresa_impostos i where i.company_id = empresa and i.estado = 'por_pagar'
               order by i.prazo nulls last limit 6) i),
    'atividade', (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'detalhe', a.detalhe, 'em', a.criado_em)
                                order by a.criado_em desc), '[]'::jsonb)
        from (select * from public.empresa_atividade a where a.company_id = empresa
               order by a.criado_em desc limit 8) a));
end $$;

create or replace function public.gestao_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  em_curso date;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  return jsonb_build_object(
    'mes_em_curso', em_curso,
    'prazo', public.prazo_documentos(em_curso),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'data_corte', c.data_corte,
        'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text),
        'documentos', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.estado <> 'pendente'),
        'por_ver', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.estado = 'recebido'),
        'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.atrasado and d.estado <> 'pendente'),
        'completo', (select em.completo_em is not null from public.empresa_meses em where em.company_id = c.id and em.mes = em_curso),
        'mensagens', (select count(*) from public.empresa_mensagens m where m.company_id = c.id and m.lida_em is null and not m.do_gabinete),
        'pessoal', (select count(*) from public.empresa_pessoal p where p.company_id = c.id and p.estado = 'novo'),
        'impostos_atrasados', (select count(*) from public.empresa_impostos i where i.company_id = c.id and i.estado = 'por_pagar' and i.prazo < hoje)))
        from public.companies c), '[]'::jsonb));
end $$;

-- ------------------------------------------------------- execute das funções
do $x$
declare f text;
begin
  foreach f in array array[
    'public.nif_valido(text)', 'public.logotipo_da_empresa(text)',
    'public.definir_inicio_empresa(uuid,date)', 'public.definir_mes_empresa(uuid,date,boolean,boolean)',
    'public.renovar_cegid_empresa(uuid)', 'public.guardar_ficha_empresa(uuid,jsonb)', 'public.ler_alerta_empresa(uuid)',
    'public.definir_logotipo_empresa(uuid,text)', 'public.comunicar_pessoal(uuid,text,text,jsonb)',
    'public.tratar_pessoal(uuid,text,text)', 'public.preparar_recibos_mes(uuid,date)',
    'public.guardar_imposto(uuid,uuid,text,text,text,text,numeric,date)', 'public.apagar_imposto(uuid)',
    'public.marcar_imposto_pago(uuid,boolean)',
    'public.preparar_ficheiro_empresa(uuid,text,uuid,text,text,bigint)', 'public.concluir_ficheiro_empresa(uuid)',
    'public.apagar_ficheiro_empresa(uuid)', 'public.registar_descarga_empresa(uuid)',
    'public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)',
    'public.marcar_mes_completo(uuid,date,boolean)', 'public.definir_data_corte(uuid,date,text)',
    'public.portal_empresas()', 'public.empresa_resumo(uuid)', 'public.gestao_empresas()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;

-- Source: 202610300062_envios_diretos.sql
-- Os ficheiros passam a ir do browser diretamente para o Storage.
--
-- Até aqui, os documentos subiam pelo servidor da aplicação, e o Vercel
-- recusa qualquer pedido com mais de 4,5 MB: três fotografias de telemóvel já
-- não passavam. Agora o servidor só regista o envio e pede ao Storage um
-- endereço de carregamento assinado; o browser envia o ficheiro para lá.
--
-- 1. Como o ficheiro já não passa pelo servidor, a conclusão confirma no
--    próprio Storage o que lá chegou: o tipo tem de ser o anunciado e o
--    tamanho passa a ser o real (nunca mais de 10 MB).
-- 2. Os envios que ficaram a meio (o browser fechou antes de carregar) saem
--    sozinhos: quem prepara um envio novo limpa os seus registos pendentes com
--    mais de seis horas e sem ficheiro.

create or replace function public.concluir_documento_empresa(documento uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos; prazo timestamptz; real_tamanho bigint; real_mime text;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(d.company_id) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  prazo := public.prazo_documentos(d.mes);
  if d.estado <> 'pendente' then
    return jsonb_build_object('id', d.id, 'atrasado', d.atrasado, 'prazo', prazo, 'mes', d.mes);
  end if;
  select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
    into real_tamanho, real_mime
    from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho;
  if not found then
    raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
  end if;
  if real_mime is distinct from d.mime or real_tamanho is null or real_tamanho not between 1 and 10485760 then
    raise exception 'O ficheiro recebido não corresponde ao anunciado' using errcode = '22023';
  end if;
  update public.empresa_documentos
     set estado = 'recebido', enviado_em = now(), atrasado = now() >= prazo, tamanho = real_tamanho
   where id = d.id;
  perform public.registar_empresa(d.company_id, case when now() >= prazo then 'documento_atrasado' else 'documento' end,
    'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') ||
    case when now() >= prazo then ' (fora do prazo)' else '' end);
  return jsonb_build_object('id', d.id, 'atrasado', now() >= prazo, 'prazo', prazo, 'mes', d.mes);
end $$;

create or replace function public.concluir_ficheiro_empresa(ficheiro uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros; real_tamanho bigint; real_mime text;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or f.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(f.company_id) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if f.estado = 'pendente' then
    select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
      into real_tamanho, real_mime
      from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho;
    if not found then
      raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
    end if;
    if real_mime is distinct from f.mime or real_tamanho is null or real_tamanho not between 1 and 10485760 then
      raise exception 'O ficheiro recebido não corresponde ao anunciado' using errcode = '22023';
    end if;
    update public.empresa_ficheiros set estado = 'carregado', carregado_em = now(), tamanho = real_tamanho where id = f.id;
    if f.contexto = 'recibos' then
      update public.empresa_recibos set publicado_em = now(), publicado_por = auth.uid() where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'recibos', 'Recibos de vencimento publicados');
    elsif f.contexto = 'comprovativo' then
      update public.empresa_impostos set estado = 'pago', pago_em = coalesce(pago_em, now()), pago_por = coalesce(pago_por, auth.uid())
       where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'imposto', 'Comprovativo de pagamento enviado: ' || f.nome);
    elsif f.contexto = 'guia' then
      perform public.registar_empresa(f.company_id, 'imposto', 'Guia de pagamento publicada: ' || f.nome);
    end if;
  end if;
  return jsonb_build_object('id', f.id, 'contexto', f.contexto, 'ref', f.ref_id);
end $$;

-- A limpeza dos envios a meio, nas duas funções que os começam.
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)'::regprocedure);
  d := replace(d, $a$  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'$a$,
$a$  delete from public.empresa_documentos d
   where d.enviado_por = eu and d.estado = 'pendente' and d.criado_em < now() - interval '6 hours'
     and not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho);
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'$a$);
  if d not like '%interval ''6 hours''%' then raise exception 'preparar_documento_empresa: texto não encontrado'; end if;
  execute d;

  d := pg_get_functiondef('public.preparar_ficheiro_empresa(uuid,text,uuid,text,text,bigint)'::regprocedure);
  d := replace(d, $a$  caminho := empresa::text || '/' || p_contexto$a$,
$a$  delete from public.empresa_ficheiros f
   where f.enviado_por = auth.uid() and f.estado = 'pendente' and f.criado_em < now() - interval '6 hours'
     and not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho);
  if (select count(*) from public.empresa_ficheiros f where f.company_id = empresa and f.estado = 'pendente'
        and f.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  caminho := empresa::text || '/' || p_contexto$a$);
  if d not like '%interval ''6 hours''%' then raise exception 'preparar_ficheiro_empresa: texto não encontrado'; end if;
  execute d;
end $x$;

revoke all on function public.concluir_documento_empresa(uuid) from public, anon;
revoke all on function public.concluir_ficheiro_empresa(uuid) from public, anon;
grant execute on function public.concluir_documento_empresa(uuid) to authenticated, service_role;
grant execute on function public.concluir_ficheiro_empresa(uuid) to authenticated, service_role;

-- Source: 202610300063_irs_envios_diretos.sql
-- O portal do IRS passa também a enviar os documentos do browser diretamente
-- para o Storage (o Vercel recusa pedidos com mais de 4,5 MB: um PDF
-- digitalizado ou uma fotografia de telemóvel já não passavam).
--
-- Como o ficheiro deixa de passar pelo servidor, a conclusão confirma no
-- próprio Storage o que lá chegou: o tipo tem de ser o anunciado e o tamanho
-- guardado passa a ser o real (nunca mais de 10 MB).

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.concluir_documento(uuid,text,uuid,text)'::regprocedure);
  d := replace(d, $a$declare doc public.documents;$a$,
                  $a$declare doc public.documents; real_tamanho bigint; real_mime text;$a$);
  d := replace(d, $a$  if not exists(select 1 from storage.objects o
                 where o.bucket_id = 'irs-documents' and o.name = doc.storage_path) then
    raise exception 'File not received' using errcode = '22023';
  end if;$a$, $a$  select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
    into real_tamanho, real_mime
    from storage.objects o where o.bucket_id = 'irs-documents' and o.name = doc.storage_path;
  if not found then
    raise exception 'File not received' using errcode = '22023';
  end if;
  if real_mime is distinct from doc.mime_type or real_tamanho is null or real_tamanho not between 1 and 10485760 then
    raise exception 'File does not match' using errcode = '22023';
  end if;$a$);
  d := replace(d, $a$     set state = 'uploaded',$a$, $a$     set state = 'uploaded', file_size = real_tamanho,$a$);
  if d not like '%File does not match%' or d not like '%file_size = real_tamanho%' or d not like '%real_mime text%' then
    raise exception 'concluir_documento: texto não encontrado';
  end if;
  execute d;
end $x$;

commit;
select 'Instalacao concluida: estrutura IRS e Gestao criada.' as resultado;
