-- ATUALIZACAO ATUAL: aplica apenas as migracoes 005–008 ainda em falta.
-- Pode repetir: preserva contas, estados de bloqueio e dados existentes.
begin;
do $update_current$
begin
 if to_regclass('public.profiles') is null or to_regprocedure('public.create_irs_case(uuid,integer)') is null then
  raise exception 'Falta a instalacao inicial 001–004. Numa base vazia use supabase/install.sql.';
 end if;
if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='onboarding_completed_at') then
 execute $migration_202610230005$
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
$migration_202610230005$;
end if;

if to_regclass('public.irs_checkouts') is null then
 execute $migration_202610230006$
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
$migration_202610230006$;
end if;

if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='documents' and column_name='content_hash') then
 execute $migration_202610230007$
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
$migration_202610230007$;
end if;

if to_regprocedure('public.get_portal_context()') is null then
 execute $migration_202610240008$
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
$migration_202610240008$;
end if;
end $update_current$;
commit;
select 'Atualizacao concluida.' as resultado,
case
 when not exists(select 1 from auth.users where lower(email)='contabilidade.rubenrodrigues@gmail.com') then 'Falta criar a conta em Authentication > Users com o email do contabilista. A atualizacao nao cria palavras-passe.'
 when not exists(select 1 from auth.users where lower(email)='contabilidade.rubenrodrigues@gmail.com' and email_confirmed_at is not null) then 'A conta existe, mas falta confirmar o email.'
 when exists(select 1 from public.profiles p join auth.users u on u.id=p.id where lower(u.email)='contabilidade.rubenrodrigues@gmail.com' and (p.disabled_at is not null or p.deleted_at is not null)) then 'O perfil do contabilista esta bloqueado ou eliminado. Reveja o estado no Supabase.'
 when exists(select 1 from public.staff_users s join auth.users u on u.id=s.user_id where lower(u.email)='contabilidade.rubenrodrigues@gmail.com' and not s.active) then 'O acesso de gestao foi desativado no banco. Nao foi reativado automaticamente.'
 else 'Conta confirmada. O acesso de contabilista sera verificado e recuperado ao entrar.' end as conta_gestao;
