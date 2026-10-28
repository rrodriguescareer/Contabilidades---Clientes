-- O relatório de atividade passa a nomear a submissão feita antes de pagar,
-- com o que o cliente aceitou nesse momento.
begin;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('submissao_aceite' in d) > 0 then return; end if;
  d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                  $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'submissao_aceite' then 'Processo submetido pelo cliente, para pagar depois'$q$);
  if position('submissao_aceite' in d) = 0 then raise exception 'relatorio_de_atividade: rótulo não encontrado'; end if;
  execute d;
end $x$;

commit;
