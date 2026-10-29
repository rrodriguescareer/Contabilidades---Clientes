-- Reembolsos e pagamentos adicionais, sempre iniciados pelo gabinete.
--
-- Reembolso: parcial ou total de um pagamento recebido. O gabinete regista-o
-- aqui; o servidor devolve o dinheiro na Stripe e cria a nota de crédito no
-- Cegid em rascunho, e volta aqui para registar o resultado de cada parte.
--
-- Pagamento adicional: um valor combinado com o cliente. O gabinete pede-o;
-- fica uma fatura-recibo em rascunho no Cegid e o cliente paga-o no portal,
-- pela Stripe, como paga a preparação.
--
-- Até aqui só havia um pagamento por processo. Passa a haver um tipo:
-- 'preparacao' (o de sempre) e 'extra'. Tudo o que procurava "o" pagamento do
-- processo (a regra de uma tentativa viva, o congelamento da recolha, a
-- prontidão, os ecrãs) passa a olhar só para a preparação.
begin;

alter table public.irs_checkouts add column if not exists tipo text not null default 'preparacao';
alter table public.irs_checkouts drop constraint if exists irs_checkouts_tipo_check;
alter table public.irs_checkouts add constraint irs_checkouts_tipo_check check (tipo in ('preparacao','extra'));
alter table public.irs_checkouts add column if not exists descricao text;
alter table public.irs_checkouts add column if not exists cegid_documento text;
alter table public.irs_checkouts add column if not exists pedido_por uuid;

drop index if exists public.one_live_checkout;
create unique index one_live_checkout on public.irs_checkouts(case_id)
  where tipo = 'preparacao' and state in ('creating','pending','unknown','paid');

create table if not exists public.reembolsos (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.client_accounts(id) on delete cascade,
  case_id uuid not null references public.irs_cases(id) on delete cascade,
  checkout_id uuid not null references public.irs_checkouts(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  motivo text not null check (length(motivo) between 3 and 500),
  estado text not null default 'a_processar' check (estado in ('a_processar','feito','falhou')),
  stripe_refund_id text,
  stripe_estado text,
  cegid_documento text,
  cegid_erro text,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index if not exists reembolsos_checkout on public.reembolsos(checkout_id);
create index if not exists reembolsos_case on public.reembolsos(case_id);
create index if not exists reembolsos_account on public.reembolsos(account_id);
alter table public.reembolsos enable row level security;
drop policy if exists reembolso_le on public.reembolsos;
create policy reembolso_le on public.reembolsos for select to authenticated
  using (account_id in (select public.readable_accounts()));
grant select on public.reembolsos to authenticated;

/* ---------------------------------------------------------- reembolsos */

create or replace function public.registar_reembolso(p_checkout uuid, p_valor integer, p_motivo text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts; ja integer; novo uuid;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into k from public.irs_checkouts where id = p_checkout for update;
  if not found or k.state <> 'paid' then raise exception 'Só se reembolsa um pagamento recebido.' using errcode = '22023'; end if;
  if k.provider_order_id is null or k.amount_cents = 0 then
    raise exception 'Este pagamento não passou pela Stripe.' using errcode = '22023';
  end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Indique o valor a reembolsar.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Indique o motivo.' using errcode = '22023'; end if;
  select coalesce(sum(amount_cents), 0) into ja from public.reembolsos
   where checkout_id = k.id and estado <> 'falhou';
  if ja + p_valor > k.amount_cents then
    raise exception 'O valor excede o que falta reembolsar (% €).', to_char((k.amount_cents - ja) / 100.0, 'FM999990D00')
      using errcode = '22023';
  end if;
  insert into public.reembolsos(account_id, case_id, checkout_id, amount_cents, motivo, criado_por)
  values (k.account_id, k.case_id, k.id, p_valor, left(btrim(p_motivo), 500), auth.uid())
  returning id into novo;
  return novo;
end $$;

create or replace function public.concluir_reembolso(
  p_reembolso uuid, p_stripe_id text, p_stripe_estado text, p_cegid text, p_cegid_erro text, p_falhou boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.reembolsos;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into r from public.reembolsos where id = p_reembolso for update;
  if not found then raise exception 'Reembolso inexistente.' using errcode = '22023'; end if;
  update public.reembolsos
     set stripe_refund_id = coalesce(p_stripe_id, stripe_refund_id),
         stripe_estado = coalesce(p_stripe_estado, stripe_estado),
         cegid_documento = coalesce(p_cegid, cegid_documento),
         cegid_erro = case when p_cegid is not null then null else coalesce(p_cegid_erro, cegid_erro) end,
         estado = case when p_falhou then 'falhou' when coalesce(p_stripe_id, stripe_refund_id) is not null then 'feito' else estado end
   where id = r.id;
  if not p_falhou and r.estado <> 'feito' and coalesce(p_stripe_id, r.stripe_refund_id) is not null then
    insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (r.account_id, r.case_id, auth.uid(), 'Reembolso processado',
            'Foi processado um reembolso de ' || public.euros_pt(r.amount_cents)
            || '. O valor é devolvido pelo mesmo meio de pagamento, normalmente em 5 a 10 dias úteis.');
  end if;
end $$;

/* --------------------------------------------------- pagamento adicional */

create or replace function public.criar_pagamento_extra(p_processo uuid, p_valor integer, p_descricao text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare caso public.irs_cases; dono uuid; novo uuid; texto text := left(btrim(coalesce(p_descricao, '')), 200);
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into caso from public.irs_cases where id = p_processo;
  if not found then raise exception 'Processo inexistente.' using errcode = '22023'; end if;
  if p_valor is null or p_valor < 50 then raise exception 'O valor mínimo é 0,50 €.' using errcode = '22023'; end if;
  if length(texto) < 3 then raise exception 'Indique a descrição do pagamento.' using errcode = '22023'; end if;
  select a.user_id into dono from public.account_access a
   where a.account_id = caso.account_id and a.role = 'owner' and a.active limit 1;
  if dono is null then raise exception 'O processo não tem titular com acesso.' using errcode = '22023'; end if;
  insert into public.irs_checkouts(account_id, case_id, user_id, quote, amount_cents, tipo, descricao, pedido_por)
  values (caso.account_id, caso.id, dono,
          jsonb_build_object('total_cents', p_valor, 'items', jsonb_build_array(
            jsonb_build_object('code', 'extra', 'label', texto, 'amount_cents', p_valor))),
          p_valor, 'extra', texto, auth.uid())
  returning id into novo;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (caso.account_id, caso.id, auth.uid(), 'Pagamento adicional pedido',
          texto || ' — ' || public.euros_pt(p_valor) || '. Pode pagar no separador Pagamento.');
  return novo;
end $$;

create or replace function public.guardar_cegid_do_pagamento(p_checkout uuid, p_documento text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  update public.irs_checkouts set cegid_documento = left(p_documento, 120) where id = p_checkout;
end $$;

create or replace function public.cancelar_pagamento_extra(p_checkout uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  select * into k from public.irs_checkouts where id = p_checkout and tipo = 'extra' for update;
  if not found then raise exception 'Pagamento adicional inexistente.' using errcode = '22023'; end if;
  if k.state in ('paid','pending','unknown') then
    raise exception 'Este pagamento já foi feito ou está a ser confirmado.' using errcode = '22023';
  end if;
  update public.irs_checkouts set state = 'cancelled' where id = k.id;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
  values (k.account_id, k.case_id, auth.uid(), 'Pagamento adicional anulado', coalesce(k.descricao, '') || ' — anulado.');
  return k.provider_order_id;
end $$;

/* O cliente abre o pagamento adicional. A sessão da Stripe é criada pelo
   servidor; aqui só se confirma que é dele e em que ponto está. */
create or replace function public.iniciar_pagamento_extra(p_checkout uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.irs_checkouts;
begin
  select * into k from public.irs_checkouts where id = p_checkout and tipo = 'extra';
  if not found or not public.can_read_account(k.account_id) or not exists(
       select 1 from public.account_access a
        where a.account_id = k.account_id and a.user_id = auth.uid() and a.role = 'owner' and a.active) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if k.state in ('cancelled','failed') then raise exception 'Este pagamento já não está disponível.' using errcode = '22023'; end if;
  return jsonb_build_object('id', k.id, 'state', k.state, 'sessao', k.provider_order_id,
                            'amount_cents', k.amount_cents, 'descricao', k.descricao);
end $$;

revoke all on function public.registar_reembolso(uuid, integer, text) from public, anon;
revoke all on function public.concluir_reembolso(uuid, text, text, text, text, boolean) from public, anon;
revoke all on function public.criar_pagamento_extra(uuid, integer, text) from public, anon;
revoke all on function public.guardar_cegid_do_pagamento(uuid, text) from public, anon;
revoke all on function public.cancelar_pagamento_extra(uuid) from public, anon;
revoke all on function public.iniciar_pagamento_extra(uuid) from public, anon;
grant execute on function public.registar_reembolso(uuid, integer, text) to authenticated;
grant execute on function public.concluir_reembolso(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function public.criar_pagamento_extra(uuid, integer, text) to authenticated;
grant execute on function public.guardar_cegid_do_pagamento(uuid, text) to authenticated;
grant execute on function public.cancelar_pagamento_extra(uuid) to authenticated;
grant execute on function public.iniciar_pagamento_extra(uuid) to authenticated;

/* O cliente cancela uma tentativa aberta. Num pagamento adicional, o pedido
   do gabinete fica de pé: só a sessão da Stripe sai. */
create or replace function public.cancelar_pagamento_aberto(attempt uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare payment public.irs_checkouts;
begin
  select * into payment from public.irs_checkouts where id = attempt for update;
  if not found or payment.user_id is distinct from auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if payment.state not in ('creating','pending') then return payment.state; end if;
  if payment.tipo = 'extra' then
    update public.irs_checkouts set state = 'creating', provider_order_id = null, checkout_url = null where id = attempt;
  else
    update public.irs_checkouts set state = 'cancelled' where id = attempt;
  end if;
  return payment.provider_order_id;
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
  if not pago and payment.state not in ('pending','unknown') then return; end if;
  update public.irs_checkouts set last_checked_at = now() where id = attempt;

  -- Pagamento adicional: não mexe na fase do processo nem nas outras tentativas.
  if payment.tipo = 'extra' then
    if pago then
      update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
      insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id, 'Pagamento adicional recebido',
              coalesce(payment.descricao, 'Pagamento adicional') || ' — ' || public.euros_pt(payment.amount_cents) || '.');
    elsif falhou then
      -- A sessão expirou: o pedido continua de pé para nova tentativa.
      update public.irs_checkouts set state = 'creating', provider_order_id = null, checkout_url = null where id = attempt;
    end if;
    return;
  end if;

  if pago then
    if exists(select 1 from public.irs_checkouts k
               where k.case_id = payment.case_id and k.tipo = 'preparacao' and k.state = 'paid' and k.id <> payment.id) then
      insert into public.task_alerts(account_id, kind) values (payment.account_id, 'pagamento_duplicado');
      return;
    end if;
    update public.irs_checkouts set state = 'cancelled'
     where case_id = payment.case_id and tipo = 'preparacao' and id <> payment.id and state in ('creating','pending','unknown');
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo foi submetido e aguarda revisão. A declaração ainda não foi entregue na AT.'
                else 'Pagamento confirmado. A fatura-recibo é emitida em seu nome e enviada para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;
revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;

do $x$
declare d text; antes text;
begin
  -- A tentativa viva, a limpeza das paradas e o congelamento: só a preparação.
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure); antes := d;
  d := replace(d, 'where case_id = process and state = ''creating'' and created_at',
                  'where case_id = process and tipo = ''preparacao'' and state = ''creating'' and created_at');
  d := replace(d, 'where case_id = process and state in (''creating'',''pending'',''unknown'',''paid'')',
                  'where case_id = process and tipo = ''preparacao'' and state in (''creating'',''pending'',''unknown'',''paid'')');
  if d = antes then raise exception 'begin_irs_checkout: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.guard_case_collection()'::regprocedure); antes := d;
  d := replace(d, 'where p.case_id = target_case and p.state in (''pending'',''unknown'')',
                  'where p.case_id = target_case and p.tipo = ''preparacao'' and p.state in (''pending'',''unknown'')');
  if d = antes then raise exception 'guard_case_collection: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.prontidao_do_processo(uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = processo order by k.created_at desc limit 1;',
                  'where k.case_id = processo and k.tipo = ''preparacao'' order by k.created_at desc limit 1;');
  if d = antes then raise exception 'prontidao_do_processo: nada para trocar'; end if;
  execute d;

  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = processo and k.state = ''paid''',
                  'where k.case_id = processo and k.tipo = ''preparacao'' and k.state = ''paid''');
  if d = antes then raise exception 'submeter_processo: nada para trocar'; end if;
  execute d;

  -- O espaço do cliente: o pagamento da preparação, os adicionais e os reembolsos.
  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure); antes := d;
  d := replace(d, 'from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''',
                  'from public.irs_checkouts k where k.case_id = processo and k.tipo = ''preparacao'' and k.state <> ''cancelled''');
  d := replace(d, '    ''ultima_do_gabinete'', (',
'    ''extras'', (
      select coalesce(jsonb_agg(jsonb_build_object(''id'', k.id, ''estado'', k.state, ''total'', k.amount_cents,
        ''descricao'', k.descricao, ''pedido_em'', k.created_at, ''pago_em'', k.paid_at) order by k.created_at desc), ''[]''::jsonb)
      from public.irs_checkouts k where k.case_id = processo and k.tipo = ''extra'' and k.state <> ''cancelled''),
    ''reembolsos'', (
      select coalesce(jsonb_agg(jsonb_build_object(''total'', r.amount_cents, ''motivo'', r.motivo, ''em'', r.criado_em)
        order by r.criado_em desc), ''[]''::jsonb)
      from public.reembolsos r where r.case_id = processo and r.estado = ''feito''),
    ''ultima_do_gabinete'', (');
  if position('''extras''' in d) = 0 or position('k.tipo = ''preparacao''' in d) = 0 then
    raise exception 'espaco_progresso: nada para trocar';
  end if;
  execute d;

  -- A consola do gabinete.
  d := pg_get_functiondef('public.espaco_gabinete(text,uuid)'::regprocedure); antes := d;
  d := replace(d, 'where k.case_id = c.id', 'where k.case_id = c.id and k.tipo = ''preparacao''');
  d := replace(d, 'from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''',
                  'from public.irs_checkouts k where k.case_id = processo and k.tipo = ''preparacao'' and k.state <> ''cancelled''');
  d := replace(d, '          ''criado'', k.created_at, ''pago_em'', k.paid_at
        ) order by k.created_at desc), ''[]''::jsonb)',
'          ''criado'', k.created_at, ''pago_em'', k.paid_at, ''tipo'', k.tipo, ''descricao'', k.descricao,
          ''reembolsado'', (select coalesce(sum(r.amount_cents), 0) from public.reembolsos r
                             where r.checkout_id = k.id and r.estado = ''feito'')
        ) order by k.created_at desc), ''[]''::jsonb)');
  d := replace(d, '    ''prontidao'', public.prontidao_do_processo(processo)',
'    ''movimentos'', (
      select coalesce(jsonb_agg(jsonb_build_object(
        ''id'', k.id, ''tipo'', k.tipo, ''estado'', k.state, ''total'', k.amount_cents, ''descricao'', k.descricao,
        ''criado'', k.created_at, ''pago_em'', k.paid_at, ''cegid'', k.cegid_documento, ''stripe'', k.provider_order_id,
        ''reembolsos'', (select coalesce(jsonb_agg(jsonb_build_object(
            ''id'', r.id, ''total'', r.amount_cents, ''motivo'', r.motivo, ''estado'', r.estado, ''em'', r.criado_em,
            ''stripe'', r.stripe_refund_id, ''cegid'', r.cegid_documento, ''cegid_erro'', r.cegid_erro)
            order by r.criado_em), ''[]''::jsonb) from public.reembolsos r where r.checkout_id = k.id)
      ) order by k.created_at), ''[]''::jsonb)
      from public.irs_checkouts k where k.case_id = processo and k.state <> ''cancelled''),
    ''prontidao'', public.prontidao_do_processo(processo)');
  if position('''movimentos''' in d) = 0 then raise exception 'espaco_gabinete: movimentos não acrescentados'; end if;
  execute d;

  -- O relatório de atividade nomeia os passos novos.
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('documento_apagado' in d) = 0 then
    d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                    $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'documento_apagado' then 'Documento apagado pelo cliente'
                 when 'reembolso' then 'Reembolso emitido pelo gabinete'
                 when 'reembolso_falhou' then 'Reembolso recusado'
                 when 'pagamento_extra' then 'Pagamento adicional pedido pelo gabinete'$q$);
    execute d;
  end if;
end $x$;

commit;
