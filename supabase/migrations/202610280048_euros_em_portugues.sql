-- Os valores do relatório saíam no formato inglês (150,000.00 €).
begin;

create or replace function public.euros_pt(cents bigint)
returns text language sql immutable set search_path = '' as $$
  select translate(to_char(cents / 100.0, 'FM999G999G990D00'), ',.', '.,') || ' €'
$$;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('public.euros_pt(' in d) > 0 then return; end if;
  d := replace(d, 'to_char(ir.amount_cents / 100.0, ''FM999G999G990D00'') || '' €''', 'public.euros_pt(ir.amount_cents)');
  d := replace(d, 'to_char(k.amount_cents / 100.0, ''FM999G990D00'') || '' €', 'public.euros_pt(k.amount_cents) || ''');
  if position('to_char(' in d) > 0 then raise exception 'relatorio_de_atividade: ficou um to_char por trocar'; end if;
  execute d;
end $x$;

commit;
