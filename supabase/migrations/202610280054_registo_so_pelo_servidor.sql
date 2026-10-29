-- O registo de atividade é a prova numa contestação de pagamento, mas o
-- cliente podia escrever nele diretamente (registar_atividade aceitava o tipo,
-- o texto, o IP e o browser vindos de quem chamava). Bastava inventar uma
-- "notificação do Stripe" para ela aparecer no relatório como vinda do Stripe.
-- Passa a escrever só o servidor, que sabe quem é o utilizador pela sessão.
begin;

create or replace function public.registar_atividade_de(
  p_user uuid, p_tipo text, p_detalhe text default null, p_case uuid default null,
  p_ip text default null, p_agente text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare conta uuid;
begin
  if p_user is null then return; end if;
  if p_case is not null then
    select c.account_id into conta
      from public.irs_cases c join public.account_access a on a.account_id = c.account_id
     where c.id = p_case and a.user_id = p_user and a.active
     limit 1;
    if conta is null then return; end if;
  else
    select a.account_id into conta from public.account_access a
     where a.user_id = p_user and a.role = 'owner' limit 1;
  end if;
  insert into public.registo_atividade(user_id, account_id, case_id, tipo, detalhe, ip, agente)
  values (p_user, conta, p_case, left(p_tipo, 60), left(p_detalhe, 2000), left(p_ip, 64), left(p_agente, 400));
end $$;
revoke all on function public.registar_atividade_de(uuid, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.registar_atividade_de(uuid, text, text, uuid, text, text) to service_role;

drop function if exists public.registar_atividade(text, text, uuid, text, text);

-- Um pagamento confirmado pela Stripe regista-se sempre. Se o cliente
-- cancelou a tentativa num separador e pagou noutro, o dinheiro entrou, mas a
-- base recusava ('Invalid payment state') e o webhook falhava para sempre.
-- Fica pago — e as outras tentativas em aberto desse processo fecham, porque
-- só pode haver uma viva. Se o processo já tinha outro pagamento, este não
-- passa a pago (seria o segundo): fica um alerta urgente para o reembolso.
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
  if pago then
    if exists(select 1 from public.irs_checkouts k
               where k.case_id = payment.case_id and k.state = 'paid' and k.id <> payment.id) then
      insert into public.task_alerts(account_id, kind) values (payment.account_id, 'pagamento_duplicado');
      return;
    end if;
    update public.irs_checkouts set state = 'cancelled'
     where case_id = payment.case_id and id <> payment.id and state in ('creating','pending','unknown');
    update public.irs_checkouts set state = 'paid', paid_at = now() where id = attempt;
    update public.irs_cases set status = 'submitted_by_client',
           submitted_by_client_at = coalesce(submitted_by_client_at, now())
     where id = payment.case_id and status in ('collecting','returned');
    submetido := found;
    insert into public.progress_events(account_id, case_id, author_id, title, body)
      values (payment.account_id, payment.case_id, payment.user_id,
              case when submetido then 'Processo submetido' else 'Pagamento recebido' end,
              case when submetido
                then 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.'
                else 'Pagamento confirmado. A fatura-recibo é emitida em seu nome e enviada para o seu email.'
              end);
  elsif falhou then
    update public.irs_checkouts set state = 'failed' where id = attempt;
  end if;
end $$;
revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;

-- As senhas das Finanças só se escrevem pelas funções que as validam
-- (guardar_membro_agregado e guardar_senha_financas). A escrita direta na
-- tabela, que a aplicação nunca usa, deixava gravar uma senha numa pessoa
-- qualquer desde que a linha apontasse para a própria conta.
drop policy if exists credencial_escreve on public.tax_credentials;
drop policy if exists credencial_atualiza on public.tax_credentials;
revoke insert, update, delete on public.tax_credentials from anon, authenticated;

commit;
