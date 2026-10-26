-- O preço passa a sair da política em vigor em vez de números no corpo da
-- função. Os valores por omissão são os que lá estavam, por isso nada muda
-- enquanto não for criada uma política.
begin;

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

commit;
