-- O espaço do cliente, revisto.
--
-- 1. Mensagens: o espaco_irs decidia se uma mensagem era do gabinete
--    perguntando à tabela staff_users — que o cliente não pode ler. Todas as
--    mensagens pareciam do cliente, incluindo as minhas respostas. Passa a
--    decidir pelo autor: se não fui eu (cliente), é do gabinete.
-- 2. O acompanhamento (e o novo Início) trazem a última mensagem do gabinete,
--    para o menu poder assinalar uma resposta nova.
-- 3. "Pagar e submeter" é um momento só. O pagamento não abre enquanto faltar
--    algo que impeça a submissão (dados do titular, senha, rendimentos), e a
--    submissão sem pagamento fica reservada a um processo devolvido, que já
--    foi pago.
begin;

do $mensagens$
declare d text;
  velho constant text := '''do_gabinete'', exists(select 1 from public.staff_users s where s.user_id = m.author_id)';
  novo constant text := '''do_gabinete'', m.author_id is distinct from auth.uid()';
begin
  d := pg_get_functiondef('public.espaco_irs(text,uuid)'::regprocedure);
  if position(velho in d) = 0 then
    if position(novo in d) > 0 then return; end if;
    raise exception 'espaco_irs: padrão das mensagens não encontrado';
  end if;
  execute replace(d, velho, novo);
end $mensagens$;

create or replace function public.espaco_progresso(processo uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  conta uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then
    return jsonb_build_object('processo', null, 'erro', 'sem_acesso');
  end if;

  return jsonb_build_object(
    'processo', (
      select jsonb_build_object('estado', c.status, 'desde', c.status_changed_at,
        'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
      from public.irs_cases c where c.id = processo),
    'prontidao', public.prontidao_do_processo(processo),
    'contagens', jsonb_build_object(
      'membros', (select count(*) from public.case_people where case_id = processo),
      'rendimentos', (select count(*) from public.income_records where case_id = processo),
      'documentos', (select count(*) from public.documents where case_id = processo),
      'mensagens', (select count(*) from public.messages where case_id = processo)),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo and k.state <> 'cancelled'
      order by k.created_at desc limit 1),
    'ultima_do_gabinete', (
      select jsonb_build_object('corpo', left(m.body, 280), 'em', m.created_at)
      from public.messages m
      where m.case_id = processo and m.author_id is distinct from auth.uid()
      order by m.created_at desc limit 1),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'consultas_senha', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'pessoa', p.full_name, 'em', v.viewed_at
      ) order by v.viewed_at desc), '[]'::jsonb)
      from public.tax_credential_views v
      join public.people p on p.id = v.person_id
      where v.account_id = conta)
  );
end $$;

-- O pagamento só abre com o processo pronto a submeter.
do $pagar$
declare d text;
  ancora constant text := 'if exists(select 1 from public.documents where case_id = process and state = ''pending'') then';
  guarda constant text := 'if exists(select 1 from jsonb_array_elements(public.prontidao_do_processo(process)) x
               where (x->>''bloqueia'')::boolean and x->>''estado'' = ''falta'') then
    raise exception ''Incomplete case'' using errcode = ''22023'';
  end if;
  ';
begin
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure);
  if position('Incomplete case' in d) > 0 then return; end if;
  if position(ancora in d) = 0 then raise exception 'begin_irs_checkout: âncora não encontrada'; end if;
  execute replace(d, ancora, guarda || ancora);
end $pagar$;

-- Submeter sem pagar só serve a quem já pagou (um processo devolvido).
do $submeter$
declare d text;
  ancora constant text := 'lista := public.prontidao_do_processo(processo);';
  guarda constant text := 'if not exists(select 1 from public.irs_checkouts k where k.case_id = processo and k.state = ''paid'') then
    raise exception ''Payment required'' using errcode = ''P0005'';
  end if;

  ';
begin
  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure);
  if position('Payment required' in d) > 0 then return; end if;
  if position(ancora in d) = 0 then raise exception 'submeter_processo: âncora não encontrada'; end if;
  execute replace(d, ancora, guarda || ancora);
end $submeter$;

commit;
