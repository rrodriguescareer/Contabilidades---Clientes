-- Pagar e submeter deixam de ser o mesmo passo obrigatório.
--
-- Até aqui só se submetia depois de pagar, e só se pagava com o processo em
-- recolha: quem submetesse (ou visse o processo avançar) já não conseguia
-- pagar. Agora:
--   - submeter não exige pagamento;
--   - o pagamento fica disponível em qualquer fase até ao fecho do processo;
--   - pagar com o processo ainda em recolha continua a submetê-lo (o botão
--     "Pagar e submeter"); pagar depois só regista o pagamento.
begin;

create or replace function public.submeter_processo(processo uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  conta uuid;
  actual text;
  lista jsonb;
  faltas text[];
  pago boolean;
begin
  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;
  if not public.can_read_account(conta) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if actual not in ('collecting','returned') then
    raise exception 'O processo já foi submetido.' using errcode = 'P0004';
  end if;
  lista := public.prontidao_do_processo(processo);
  select array_agg(x->>'rotulo') into faltas
    from jsonb_array_elements(lista) x
   where (x->>'bloqueia')::boolean and x->>'estado' = 'falta';

  if faltas is not null then
    return jsonb_build_object('ok', false, 'faltas', to_jsonb(faltas), 'prontidao', lista);
  end if;

  pago := exists(select 1 from public.irs_checkouts k where k.case_id = processo and k.state = 'paid');

  update public.irs_cases
     set status = 'submitted_by_client',
         submitted_by_client_at = coalesce(submitted_by_client_at, now())
   where id = processo;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(), 'Processo submetido',
            case when pago
              then 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.'
              else 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar. O pagamento pode ser feito a qualquer momento no separador Pagamento.'
            end);

  return jsonb_build_object('ok', true, 'estado', 'submitted_by_client', 'pago', pago);
end $$;

create or replace function public.begin_irs_checkout(
  account uuid, process uuid, coupon text default '', expected_total integer default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare quote jsonb; attempt public.irs_checkouts; estado text; em_recolha boolean;
begin
  if not public.can_read_account(account) or not exists(
       select 1 from public.account_access a
        where a.account_id = account and a.user_id = auth.uid()
          and a.role = 'owner' and a.active and a.irs) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select c.status into estado from public.irs_cases c
   where c.id = process and c.account_id = account for update;
  if not found then raise exception 'Process unavailable'; end if;
  em_recolha := estado in ('collecting','returned');

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

  if estado = 'closed' then
    raise exception 'Case is closed';
  end if;
  if not exists(select 1 from public.case_people where case_id = process and relationship = 'titular') then
    raise exception 'Holder missing';
  end if;
  -- Em recolha, pagar também submete: tem de estar pronto. Depois de
  -- submetido, a prontidão já foi verificada na submissão.
  if em_recolha and exists(
       select 1 from jsonb_array_elements(public.prontidao_do_processo(process)) x
        where (x->>'bloqueia')::boolean and x->>'estado' = 'falta') then
    raise exception 'Incomplete case' using errcode = '22023';
  end if;
  if em_recolha and exists(
       select 1 from public.documents
        where case_id = process and state = 'pending' and created_at > now() - interval '15 minutes') then
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
    if em_recolha then
      update public.irs_cases set status = 'submitted_by_client',
             submitted_by_client_at = coalesce(submitted_by_client_at, now())
       where id = process;
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (account, process, auth.uid(), 'Processo submetido',
              'Processo enviado para revisão com desconto integral. Não representa submissão à AT.');
    else
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (account, process, auth.uid(), 'Pagamento registado', 'Desconto integral: nada a pagar.');
    end if;
  end if;

  return jsonb_build_object('id', attempt.id,
    'state', case when attempt.amount_cents = 0 then 'paid' else 'creating' end,
    'created', true, 'amount_cents', attempt.amount_cents);
end $$;

create or replace function public.finalizar_pagamento_stripe(
  attempt uuid, provider_id text, provider_reference text, pago boolean, falhou boolean,
  provider_amount integer, provider_currency text)
returns void language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts; submetido boolean;
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
    -- Pagar com o processo em recolha é "pagar e submeter".
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.'
                else 'Pagamento confirmado. A fatura-recibo segue para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;

commit;
