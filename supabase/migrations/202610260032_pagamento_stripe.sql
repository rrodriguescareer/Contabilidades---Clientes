-- Liquidação de um pagamento Stripe.
-- Mantém as garantias da via anterior: só avança se o identificador, a
-- referência, o montante e a moeda baterem certo; é idempotente; e só sai
-- dos estados pending/unknown.
begin;

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

commit;
