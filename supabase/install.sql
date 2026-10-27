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

commit;
select 'Instalacao concluida: estrutura IRS e Gestao criada.' as resultado;
