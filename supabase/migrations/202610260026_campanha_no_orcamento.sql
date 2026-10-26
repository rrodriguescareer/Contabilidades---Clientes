-- A campanha em vigor entra no orçamento.
-- Não acumula com o código de desconto: aplica-se o maior dos dois. Acumular
-- dá descontos que ninguém tencionou, e é mais fácil de explicar assim.
begin;

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

commit;
