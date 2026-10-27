-- O Início, o Acompanhamento e o Pagamento do cliente leem a mesma função:
-- o pagamento precisa da prontidão (para dizer o que falta antes de pagar) e
-- o Início precisa do pagamento. Acrescenta-se o detalhe do último pagamento.
begin;

do $p$
declare d text;
  velho constant text := 'select jsonb_build_object(''estado'', k.state, ''total'', k.amount_cents, ''pago_em'', k.paid_at)';
  novo constant text := 'select jsonb_build_object(''id'', k.id, ''estado'', k.state, ''total'', k.amount_cents, ''pago_em'', k.paid_at, ''desconto'', k.discount_cents, ''detalhe'', k.quote)';
begin
  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure);
  if position(novo in d) > 0 then return; end if;
  if position(velho in d) = 0 then raise exception 'espaco_progresso: padrão do pagamento não encontrado'; end if;
  execute replace(d, velho, novo);
end $p$;

commit;
