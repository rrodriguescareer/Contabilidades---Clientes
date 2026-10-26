-- A migracao anterior trocou o vocabulario dos estados do processo, mas havia
-- funcoes a escrever 'review' e a ler 'missing'/'completed'. Contra a
-- restricao nova, rebentavam em producao. Sao reescritas a partir da propria
-- definicao, para nao haver erros de transcricao.
begin;

do $rewrite$
declare
  f record;
  fonte text;
  pares text[][] := array[
    array['''collecting'',''missing''', ''''||'collecting'''],
    array['''collecting'', ''missing''', ''''||'collecting'''],
    array['''review''', '''submitted_by_client'''],
    array['''authorization''', '''approved'''],
    array['''completed''', '''closed'''],
    array['''submitted''', '''filed'''],
    array['''missing''', '''validation''']
  ];
  par text[];
begin
  for f in
    select p.oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ~ '''(review|missing|authorization|completed|submitted)'''
  loop
    fonte := pg_get_functiondef(f.oid);
    foreach par slice 1 in array pares loop
      fonte := replace(fonte, par[1], par[2]);
    end loop;
    execute fonte;
  end loop;
end $rewrite$;

-- Se sobrar algum literal antigo, a instalacao para aqui em vez de seguir
-- com funcoes que violam a restricao dos estados.
do $check$
declare n int;
begin
  select count(*) into n
  from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
  where nsp.nspname = 'public' and p.prokind = 'f'
    and pg_get_functiondef(p.oid) ~ '''(review|missing|authorization|completed)''';
  if n > 0 then
    raise exception 'Restam % funcoes com estados antigos.', n;
  end if;
end $check$;

commit;
