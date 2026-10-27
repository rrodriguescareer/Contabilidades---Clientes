-- Com uma ordem aberta no fornecedor (pending/unknown), o processo fica
-- congelado para todos — também para o gabinete: o valor já foi apresentado
-- ao cliente e não pode mudar debaixo dele. Uma tentativa ainda em "creating"
-- não congela nada.
begin;

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

commit;
