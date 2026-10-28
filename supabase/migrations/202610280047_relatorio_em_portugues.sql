-- O relatório de atividade mostrava os códigos internos (employment,
-- conjuge…) onde devia dizer "Trabalho dependente", "Cônjuge"…
begin;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('Trabalho dependente' in d) > 0 then return; end if;
  if position('coalesce(ir.kind, ir.title), ir.category,' in d) = 0 or position('''NIF '' || pe.nif, cp.relationship))' in d) = 0 then
    raise exception 'relatorio_de_atividade: padrões não encontrados';
  end if;
  d := replace(d, 'coalesce(ir.kind, ir.title), ir.category,',
    'coalesce(ir.kind, ir.title), case ir.category when ''employment'' then ''Trabalho dependente'' when ''pension'' then ''Pensões''
       when ''independent'' then ''Trabalho independente'' when ''securities'' then ''Capitais e valores mobiliários''
       when ''property_rent'' then ''Rendas'' when ''property_sale'' then ''Mais-valias de imóveis''
       when ''foreign_income'' then ''Rendimentos estrangeiros'' else ir.category end,');
  d := replace(d, '''NIF '' || pe.nif, cp.relationship))',
    '''NIF '' || pe.nif, case cp.relationship when ''titular'' then ''Titular'' when ''conjuge'' then ''Cônjuge''
       when ''descendente'' then ''Descendente'' when ''ascendente'' then ''Ascendente'' else cp.relationship end))');
  execute d;
end $x$;

commit;
