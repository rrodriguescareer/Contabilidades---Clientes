-- Três correções ao fluxo, encontradas a verificar a migração anterior.
--
-- 1. O can_edit_case só considerava "collecting" editável. Um processo
--    devolvido ficaria em "returned" e o cliente não lhe podia tocar — era o
--    contrário do que "devolvido para completar" significa.
-- 2. A prontidão usava o can_edit_case como porta de leitura: assim que o
--    processo saísse da recolha, o cliente deixava de ver a sua própria lista.
--    A leitura passa a ser quem lê a conta.
-- 3. O submeter_processo tinha o mesmo problema, e ainda ficava bloqueado por
--    um pagamento pendente (o Multibanco demora horas). A autorização é ler a
--    conta; o estado já é verificado à parte.
begin;

create or replace function public.can_edit_case(account uuid, caseid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_staff() or (
    public.can_read_account(account)
    and exists(select 1 from public.irs_cases c
                where c.id = caseid and c.account_id = account
                  and c.status in ('collecting','returned'))
    and not exists(select 1 from public.irs_checkouts p
                    where p.case_id = caseid and p.state in ('creating','pending','unknown')))
$$;

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
  if not public.can_read_account(conta) then
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
  if not public.can_read_account(conta) then
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

commit;
