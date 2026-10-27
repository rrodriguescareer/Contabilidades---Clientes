-- O fluxo do processo tinha nove estados em linha e dois buracos: um processo
-- devolvido ficava igual a um que nunca começou, e o cliente não tinha forma
-- de submeter o seu próprio processo — só eu o podia marcar como submetido.
--
-- Esta migração: (1) acrescenta "returned", "assessed" e "divergence", que são
-- níveis reais do processo; (2) dá ao cliente a ação de submeter, com
-- pré-requisitos verificados no servidor; (3) põe num sítio só a lista de
-- prontidão que as duas óticas mostram.
begin;

-- 1. Os estados novos.
alter table public.irs_cases drop constraint irs_cases_status_check;
alter table public.irs_cases add constraint irs_cases_status_check
  check (status = any (array[
    'collecting','returned','submitted_by_client','accepted','validation',
    'approved','submitting','filed','monitoring','divergence','assessed','closed']));

-- 2. O grafo. "returned" é o caminho de volta: substitui o antigo
--    "devolver para collecting", que apagava o facto de ter sido devolvido.
create or replace function public.transicoes_do_estado(actual text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case actual
    when 'collecting'          then array['submitted_by_client']
    when 'returned'            then array['submitted_by_client','accepted']
    when 'submitted_by_client' then array['accepted','returned']
    when 'accepted'            then array['validation','returned']
    when 'validation'          then array['approved','returned']
    when 'approved'            then array['submitting','validation']
    when 'submitting'          then array['filed','approved']
    when 'filed'               then array['monitoring']
    when 'monitoring'          then array['assessed','divergence','closed','filed']
    when 'divergence'          then array['assessed','monitoring']
    when 'assessed'            then array['closed','divergence']
    when 'closed'              then array['assessed','monitoring']
    else array[]::text[] end
$$;

-- 3. Os rótulos e os corpos dos eventos, com os estados novos. O resto da
--    função é o que já lá estava.
create or replace function public.avancar_processo(
  processo uuid, destino text, nota text default '',
  valor_cents bigint default null, sentido text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  rotulos jsonb := jsonb_build_object(
    'submitted_by_client','Processo submetido',
    'accepted','Processo aceite',
    'validation','Em validação',
    'approved','Aprovado',
    'submitting','Em processo de submissão',
    'filed','Submetido na Autoridade Tributária',
    'monitoring','Em acompanhamento',
    'divergence','Em divergência',
    'assessed','Liquidação emitida',
    'closed','Processo fechado',
    'returned','Devolvido para completar',
    'collecting','Recolha reaberta');
  -- O corpo do evento nunca pode ficar vazio: sem nota, explica-se o passo.
  corpos jsonb := jsonb_build_object(
    'submitted_by_client','O processo foi submetido e entrou na minha fila.',
    'accepted','Recebi o processo e abri-o para análise.',
    'validation','Estou a conferir os rendimentos e os documentos.',
    'approved','Está tudo conferido. O processo segue para submissão.',
    'submitting','A declaração está a ser entregue na Autoridade Tributária.',
    'filed','A declaração foi entregue.',
    'monitoring','À espera da validação da Autoridade Tributária.',
    'divergence','A Autoridade Tributária levantou uma divergência. Vou tratar dela e aviso-o do que for preciso.',
    'assessed','A liquidação foi emitida. O valor apurado está confirmado.',
    'closed','O processo está concluído.',
    'returned','Faltam elementos. Pode completar o processo e submeter outra vez.',
    'collecting','A recolha foi reaberta.');
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;

  if not (destino = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, destino;
  end if;

  if destino = 'filed' then
    if valor_cents is null or sentido is null then
      raise exception 'Indique o valor apurado e se e a reembolsar ou a pagar.';
    end if;
    if sentido not in ('refund','payment') or valor_cents < 0 then
      raise exception 'Valor apurado invalido.';
    end if;
    update public.irs_cases
       set status = destino, final_amount_cents = valor_cents, final_direction = sentido
     where id = processo;
  else
    update public.irs_cases set status = destino where id = processo;
  end if;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(),
            coalesce(rotulos->>destino, destino),
            coalesce(nullif(trim(nota), ''), corpos->>destino, destino));

  return destino;
end $$;

-- 4. A prontidão do processo. É a mesma lista nas duas óticas: o cliente vê o
--    que falta da parte dele, eu vejo tudo antes de aprovar. "bloqueia" marca
--    o que impede a submissão pelo cliente; o pagamento e o 2FA não impedem,
--    avisam.
create or replace function public.prontidao_do_processo(processo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conta uuid;
  titular public.people;
  com_senha boolean;
  com_2fa int;
  rendimentos int;
  documentos int;
  pago text;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then return '[]'::jsonb; end if;
  if not (public.is_staff() or public.can_edit_case(conta, processo)) then
    return '[]'::jsonb;
  end if;

  select p.* into titular
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and cp.relationship = 'titular' limit 1;

  select exists(select 1 from public.tax_credentials tc where tc.person_id = titular.id)
    into com_senha;

  select count(*) into com_2fa
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and p.tax_two_factor;

  select count(*) into rendimentos from public.income_records where case_id = processo;
  select count(*) into documentos from public.documents where case_id = processo;

  select k.state into pago from public.irs_checkouts k
   where k.case_id = processo order by k.created_at desc limit 1;

  return jsonb_build_array(
    jsonb_build_object(
      'chave','titular', 'de','cliente', 'bloqueia', true,
      'rotulo','Dados do titular',
      'estado', case when titular.nif is not null and titular.birth_date is not null
                     then 'ok' else 'falta' end,
      'detalhe', case when titular.nif is null then 'Falta o NIF.'
                      when titular.birth_date is null then 'Falta a data de nascimento.'
                      else coalesce(titular.full_name,'') end),
    jsonb_build_object(
      'chave','senha', 'de','cliente', 'bloqueia', true,
      'rotulo','Senha das Finanças do titular',
      'estado', case when com_senha then 'ok' else 'falta' end,
      'detalhe', case when com_senha then 'Guardada e cifrada.'
                      else 'Sem a senha não consigo entrar no Portal das Finanças.' end),
    jsonb_build_object(
      'chave','rendimentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Rendimentos declarados',
      'estado', case when rendimentos > 0 then 'ok' else 'falta' end,
      'detalhe', case when rendimentos > 0 then rendimentos || ' linha(s).'
                      else 'Declare pelo menos uma categoria de rendimento.' end),
    jsonb_build_object(
      'chave','documentos', 'de','cliente', 'bloqueia', false,
      'rotulo','Documentos enviados',
      'estado', case when documentos > 0 then 'ok' else 'atencao' end,
      'detalhe', case when documentos > 0 then documentos || ' ficheiro(s).'
                      else 'Ainda não enviou documentos. Pode submeter sem eles, mas posso pedir-lhos.' end),
    jsonb_build_object(
      'chave','dois_fatores', 'de','gabinete', 'bloqueia', false,
      'rotulo','Autenticação de dois fatores',
      'estado', case when com_2fa > 0 then 'atencao' else 'ok' end,
      'detalhe', case when com_2fa > 0
                      then com_2fa || ' pessoa(s) com 2FA: é preciso contacto na hora da submissão.'
                      else 'Ninguém do agregado tem 2FA ativo.' end),
    jsonb_build_object(
      'chave','pagamento', 'de','cliente', 'bloqueia', false,
      'rotulo','Pagamento da preparação',
      'estado', case pago when 'paid' then 'ok' when 'pending' then 'atencao' else 'falta' end,
      'detalhe', case pago
                   when 'paid' then 'Recebido.'
                   when 'pending' then 'A aguardar liquidação — o Multibanco pode levar horas.'
                   when 'failed' then 'A última tentativa falhou.'
                   else 'Ainda não foi pago.' end)
  );
end $$;

grant execute on function public.prontidao_do_processo(uuid) to authenticated;

-- 5. O cliente submete o seu processo. Era o primeiro passo do percurso e não
--    existia: só o gabinete conseguia marcar o processo como submetido.
create or replace function public.submeter_processo(processo uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  lista jsonb;
  faltas text[];
begin
  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;
  if not (public.can_edit_case(conta, processo) or public.is_staff()) then
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

  update public.irs_cases
     set status = 'submitted_by_client',
         submitted_by_client_at = coalesce(submitted_by_client_at, now())
   where id = processo;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(), 'Processo submetido',
            'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.');

  return jsonb_build_object('ok', true, 'estado', 'submitted_by_client');
end $$;

grant execute on function public.submeter_processo(uuid) to authenticated;

-- 6. A vista do acompanhamento. O espaco_irs('progresso') devolvia o estado,
--    os eventos e as consultas à senha — e nada sobre o que falta ou sobre o
--    pagamento, que é justamente o que o cliente precisa de ver. Em vez de
--    mexer naquela função (é grande e serve sete vistas), o acompanhamento
--    passa a ter a sua. Sem security definer: quem vê é quem a RLS deixa ver.
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
      'documentos', (select count(*) from public.documents where case_id = processo)),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo
      order by k.created_at desc limit 1),
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

grant execute on function public.espaco_progresso(uuid) to authenticated;

commit;
