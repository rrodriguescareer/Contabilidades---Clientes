-- Três mudanças pedidas para o espaço do cliente.
--
-- 1. Os documentos passam a ser obrigatórios em todos os separadores: cada
--    tipo de rendimento declarado (e as deduções, quando há alguma) precisa de
--    pelo menos um documento antes de se poder submeter.
-- 2. O cliente pode apagar um documento enquanto o processo está em
--    preparação. O ficheiro sai do Storage pelo servidor; aqui sai a linha.
-- 3. Os textos que a base escreve passam a um português formal e impessoal,
--    sem "está comigo", "minha fila" ou "aviso-o".
begin;

create or replace function public.prontidao_do_processo(processo uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  conta uuid;
  titular public.people;
  com_senha boolean;
  com_2fa int;
  rendimentos int;
  sem_documentos text[];
  pago text;
  deducoes public.case_deductions;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then return '[]'::jsonb; end if;
  if not public.can_read_account(conta) then return '[]'::jsonb; end if;

  select p.* into titular
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and cp.relationship = 'titular' limit 1;

  select exists(select 1 from public.tax_credentials tc where tc.person_id = titular.id) into com_senha;

  select count(*) into com_2fa
    from public.case_people cp join public.people p on p.id = cp.person_id
   where cp.case_id = processo and p.tax_two_factor;

  select count(*) into rendimentos from public.income_records where case_id = processo;

  -- Cada tipo de rendimento declarado precisa de um documento seu. Os
  -- capitais e as mais-valias de ações partilham a categoria na base.
  select array_agg(rotulo order by ordem) into sem_documentos from (
    select distinct
      case ir.category
        when 'employment' then 'Trabalho Dependente'
        when 'pension' then 'Pensões'
        when 'independent' then 'Independente'
        when 'securities' then 'Capitais e Mais-Valias (Ações e Outros)'
        when 'property_rent' then 'Rendas'
        when 'property_sale' then 'Mais-Valias (Imóveis)'
        when 'foreign_income' then 'Rendimentos Estrangeiros'
        else 'Outros rendimentos' end as rotulo,
      case ir.category
        when 'employment' then 1 when 'pension' then 2 when 'independent' then 3
        when 'securities' then 4 when 'property_rent' then 5 when 'property_sale' then 6
        when 'foreign_income' then 7 else 8 end as ordem
      from public.income_records ir
     where ir.case_id = processo
       and not exists(select 1 from public.documents d
                       where d.case_id = processo and d.state <> 'pending'
                         and (d.category = ir.category or d.income_id = ir.id))
  ) t;

  select * into deducoes from public.case_deductions where case_id = processo;
  if (deducoes.ppr or deducoes.ascendant_expenses or deducoes.rented_home)
     and not exists(select 1 from public.documents d
                     where d.case_id = processo and d.state <> 'pending' and d.category = 'deduction') then
    sem_documentos := coalesce(sem_documentos, '{}') || 'Deduções e Benefícios'::text;
  end if;

  select k.state into pago from public.irs_checkouts k
   where k.case_id = processo order by k.created_at desc limit 1;

  return jsonb_build_array(
    jsonb_build_object(
      'chave','titular', 'de','cliente', 'bloqueia', true,
      'rotulo','Dados do titular',
      'estado', case when titular.nif is not null and titular.birth_date is not null then 'ok' else 'falta' end,
      'detalhe', case when titular.nif is null then 'Falta indicar o NIF.'
                      when titular.birth_date is null then 'Falta indicar a data de nascimento.'
                      else coalesce(titular.full_name,'') end),
    jsonb_build_object(
      'chave','senha', 'de','cliente', 'bloqueia', true,
      'rotulo','Senha do Portal das Finanças',
      'estado', case when com_senha then 'ok' else 'falta' end,
      'detalhe', case when com_senha then 'Guardada de forma cifrada.'
                      else 'É necessária para preparar e entregar a declaração.' end),
    jsonb_build_object(
      'chave','rendimentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Rendimentos declarados',
      'estado', case when rendimentos > 0 then 'ok' else 'falta' end,
      'detalhe', case when rendimentos > 0 then rendimentos || ' rendimento(s) declarado(s).'
                      else 'Declare pelo menos um rendimento.' end),
    jsonb_build_object(
      'chave','documentos', 'de','cliente', 'bloqueia', true,
      'rotulo','Documentos de suporte',
      'estado', case when rendimentos = 0 then 'falta'
                     when sem_documentos is null then 'ok' else 'falta' end,
      'detalhe', case when rendimentos = 0 then 'Envie os documentos de cada rendimento que declarar.'
                      when sem_documentos is null then 'Todos os rendimentos têm documentos.'
                      else 'Falta pelo menos um documento em: ' || array_to_string(sem_documentos, ', ') || '.' end),
    jsonb_build_object(
      'chave','dois_fatores', 'de','gabinete', 'bloqueia', false,
      'rotulo','Autenticação de dois fatores',
      'estado', case when com_2fa > 0 then 'atencao' else 'ok' end,
      'detalhe', case when com_2fa > 0
                      then com_2fa || ' pessoa(s) com dois fatores: será necessário contacto no momento da entrega.'
                      else 'Nenhum membro do agregado tem dois fatores ativos.' end),
    jsonb_build_object(
      'chave','pagamento', 'de','cliente', 'bloqueia', false,
      'rotulo','Pagamento da preparação',
      'estado', case pago when 'paid' then 'ok' when 'pending' then 'atencao' else 'falta' end,
      'detalhe', case pago
                   when 'paid' then 'Recebido.'
                   when 'pending' then 'A aguardar confirmação — o Multibanco pode demorar algumas horas.'
                   when 'failed' then 'A última tentativa não foi concluída.'
                   else 'Ainda não foi feito.' end)
  );
end $$;

/* Apagar um documento: só com o processo em preparação (é o que o
   can_edit_case permite), e só os da própria conta. Devolve o caminho do
   ficheiro para o servidor o apagar do Storage — a não ser que outro documento
   do processo use o mesmo ficheiro (os repetidos partilham-no). */
create or replace function public.apagar_documento(p_documento uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare doc public.documents;
begin
  select * into doc from public.documents where id = p_documento for update;
  if not found or not public.can_read_account(doc.account_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not public.can_edit_case(doc.account_id, doc.case_id) then
    raise exception 'Collection locked' using errcode = '42501';
  end if;
  delete from public.document_downloads where document_id = doc.id;
  delete from public.documents where id = doc.id;
  if exists(select 1 from public.documents d where d.storage_path = doc.storage_path) then
    return null;
  end if;
  return doc.storage_path;
end $$;
revoke all on function public.apagar_documento(uuid) from public, anon;
grant execute on function public.apagar_documento(uuid) to authenticated;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.avancar_processo(uuid,text,text,bigint,text)'::regprocedure);
  d := replace(d, 'Recebi o processo e abri-o para análise.', 'O processo foi aceite e está em análise.');
  d := replace(d, 'Estou a conferir os rendimentos e os documentos.', 'Os rendimentos e os documentos estão a ser conferidos.');
  d := replace(d, 'A Autoridade Tributária levantou uma divergência. Vou tratar dela e aviso-o do que for preciso.',
                  'A Autoridade Tributária identificou uma divergência. O assunto está a ser tratado e será informado se for necessário algum elemento.');
  d := replace(d, 'O processo foi submetido e entrou na minha fila.', 'O processo foi submetido e aguarda revisão.');
  execute d;

  d := pg_get_functiondef('public.submeter_processo(uuid)'::regprocedure);
  d := replace(d, 'Submeteu o processo. Entrou na minha fila e aviso-o quando o aceitar.',
                  'O processo foi submetido e aguarda revisão. Será informado de cada avanço.');
  execute d;

  d := pg_get_functiondef('public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text)'::regprocedure);
  d := replace(d, 'Pagamento confirmado. O processo entrou na minha fila para revisão. A declaração ainda não foi submetida à AT.',
                  'Pagamento confirmado. O processo foi submetido e aguarda revisão. A declaração ainda não foi entregue na AT.');
  execute d;
end $x$;

commit;
