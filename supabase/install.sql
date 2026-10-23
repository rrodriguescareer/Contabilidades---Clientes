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
  'task_alerts','invitation_requests','legal_acceptances'
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

commit;
select 'Instalacao concluida: estrutura IRS e Gestao criada.' as resultado;
