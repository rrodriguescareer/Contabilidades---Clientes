begin;
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

commit;
