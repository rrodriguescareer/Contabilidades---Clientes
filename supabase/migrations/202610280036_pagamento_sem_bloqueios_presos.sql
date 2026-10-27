-- Uma tentativa de pagamento que falhava antes de chegar ao Stripe ficava em
-- "creating" para sempre — e o can_edit_case trancava o processo inteiro
-- enquanto houvesse uma: o cliente deixava de conseguir acrescentar membros,
-- guardar senhas ou rendimentos. Era essa a origem de metade dos "dá erro".
--
-- 1. "creating" deixa de trancar: é um estado de segundos, não um pagamento.
-- 2. Uma tentativa "creating" com mais de 15 minutos é abandonada (cancelled)
--    quando o cliente volta a pagar, em vez de ser devolvida outra vez.
-- 3. O pagamento confirmado também submete um processo devolvido.
begin;

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

commit;
