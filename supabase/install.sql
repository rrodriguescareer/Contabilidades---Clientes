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

commit;
select 'Instalacao concluida: estrutura IRS e Gestao criada.' as resultado;
