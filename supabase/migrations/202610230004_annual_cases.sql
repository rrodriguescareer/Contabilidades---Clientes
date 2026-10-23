-- Shared production schema: apply once, after migrations 001–003.
begin;

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
