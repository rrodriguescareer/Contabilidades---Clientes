-- As duas saídas para um conflito de NIF, pedidas pelo próprio utilizador.
--
-- Mexem em dados de outra conta, por isso: exigem uma palavra de confirmação,
-- recusam-se quando a outra conta já tem histórico a sério (processo
-- submetido ou pagamento), e deixam sempre rasto em management_audit.
begin;

create or replace function public.apagar_conta_do_nif(contribuinte text, confirmacao text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  alvo uuid;
  conta uuid;
  apagados jsonb;
  ficheiros text[];
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'APAGAR' then raise exception 'Falta a confirmacao.'; end if;
  if contribuinte !~ '^[0-9]{9}$' then raise exception 'NIF invalido.'; end if;

  select id into alvo from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;
  if alvo is null then raise exception 'Nao ha conta anterior com este NIF.'; end if;

  select a.account_id into conta from public.account_access a
   where a.user_id = alvo order by a.role limit 1;
  if conta is null then raise exception 'Conta anterior nao encontrada.'; end if;

  -- Travão: histórico a sério não se apaga sozinho.
  if exists(
    select 1 from public.irs_cases c
     where c.account_id = conta
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'A conta anterior tem um processo submetido ou pago. O contabilista tem de a tratar.';
  end if;

  select coalesce(array_agg(d.storage_path), array[]::text[]) into ficheiros
    from public.documents d where d.account_id = conta;

  apagados := jsonb_build_object(
    'rendimentos', (select count(*) from public.income_records where account_id = conta),
    'documentos', (select count(*) from public.documents where account_id = conta),
    'pessoas', (select count(*) from public.people where account_id = conta),
    'processos', (select count(*) from public.irs_cases where account_id = conta));

  delete from public.document_downloads where account_id = conta;
  delete from public.documents where account_id = conta;
  delete from public.income_records where account_id = conta;
  delete from public.case_notes where account_id = conta;
  delete from public.case_deductions where account_id = conta;
  delete from public.property_assets where account_id = conta;
  delete from public.messages where account_id = conta;
  delete from public.progress_events where account_id = conta;
  delete from public.irs_checkouts where account_id = conta;
  delete from public.task_alerts where account_id = conta;
  delete from public.household_invitations where account_id = conta;
  delete from public.invitation_requests where account_id = conta;
  delete from public.tax_credential_views where account_id = conta;
  delete from public.tax_credentials where account_id = conta;
  delete from public.case_people where account_id = conta;
  delete from public.people where account_id = conta;
  delete from public.irs_cases where account_id = conta;
  delete from public.account_access where account_id = conta;
  delete from public.client_accounts where id = conta;

  -- O utilizador em si fica marcado como eliminado: apagar a conta Auth
  -- pertence à administração, não a esta função.
  update public.profiles set deleted_at = now(), nif = null where id = alvo;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, alvo, 'nif_conta_apagada');

  return jsonb_build_object('apagados', apagados, 'ficheiros', to_jsonb(ficheiros));
end $$;

/* A migração sai de um agregado alheio para conta própria.
   Primeiro passo: diz o que há para mover, sem mover nada. */
create or replace function public.preparar_migracao_do_agregado(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'O processo do outro agregado ja foi submetido ou pago. O contabilista tem de o tratar.';
  end if;

  return jsonb_build_object(
    'pessoa', pessoa.id,
    'processo_antigo', pessoa.case_id,
    'relacao', pessoa.relationship,
    'rendimentos', (select count(*) from public.income_records
                     where case_id = pessoa.case_id and person_id = pessoa.id),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'caminho', d.storage_path, 'nome', d.file_name, 'tipo', d.kind,
        'categoria', d.category, 'descricao', d.description, 'mime', d.mime_type,
        'tamanho', d.file_size, 'hash', d.content_hash, 'rendimento', d.income_id)), '[]'::jsonb)
      from public.documents d
      join public.income_records ir on ir.id = d.income_id
      where ir.case_id = pessoa.case_id and ir.person_id = pessoa.id));
end $$;

/* Segundo passo: já com os ficheiros copiados para os caminhos novos, move
   as linhas numa transação só.
   A senha das Finanças não migra, de propósito: a pessoa volta a escrevê-la
   na conta nova. Uma credencial que muda de dono sem passar pelo dono deixa
   de ser uma credencial. */
create or replace function public.concluir_migracao_do_agregado(
  contribuinte text,
  confirmacao text,
  documentos jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  pessoa record;
  minha_conta uuid;
  meu_processo uuid;
  meu_titular uuid;
  doc jsonb;
  movidos int := 0;
  rendimentos int := 0;
begin
  if eu is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  if confirmacao <> 'MIGRAR' then raise exception 'Falta a confirmacao.'; end if;

  select p.id, p.account_id, cp.case_id, cp.relationship
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte and cp.relationship <> 'titular'
   limit 1;
  if pessoa.id is null then raise exception 'Nao ha agregado de onde sair.'; end if;

  if exists(
    select 1 from public.irs_cases c
     where c.id = pessoa.case_id
       and (c.status <> 'collecting'
            or exists(select 1 from public.irs_checkouts k
                       where k.case_id = c.id and k.state = 'paid'))) then
    raise exception 'O processo do outro agregado ja foi submetido ou pago.';
  end if;

  select a.account_id into minha_conta from public.account_access a
   where a.user_id = eu order by a.role limit 1;
  if minha_conta is null then raise exception 'Complete primeiro o seu registo.'; end if;

  select id into meu_processo from public.irs_cases
   where account_id = minha_conta order by tax_year desc limit 1;
  if meu_processo is null then raise exception 'Nao tem processo aberto.'; end if;

  select cp.person_id into meu_titular from public.case_people cp
   where cp.case_id = meu_processo and cp.relationship = 'titular';
  if meu_titular is null then raise exception 'Falta o titular no seu processo.'; end if;

  update public.income_records
     set account_id = minha_conta, case_id = meu_processo, person_id = meu_titular
   where case_id = pessoa.case_id and person_id = pessoa.id;
  get diagnostics rendimentos = row_count;

  -- Os documentos são recriados no caminho novo: o caminho antigo tem a
  -- conta e o processo antigos lá dentro, e há uma restrição que o exige.
  for doc in select * from jsonb_array_elements(documentos) loop
    insert into public.documents(
      id, account_id, case_id, income_id, kind, file_name, storage_path,
      mime_type, file_size, state, uploaded_by, content_hash, category, description)
    values (
      (doc->>'novo_id')::uuid, minha_conta, meu_processo,
      (doc->>'rendimento')::uuid, doc->>'tipo', doc->>'nome', doc->>'novo_caminho',
      doc->>'mime', (doc->>'tamanho')::bigint, 'uploaded', eu,
      doc->>'hash', doc->>'categoria', doc->>'descricao');
    delete from public.documents where id = (doc->>'id')::uuid;
    movidos := movidos + 1;
  end loop;

  delete from public.tax_credential_views where person_id = pessoa.id;
  delete from public.tax_credentials where person_id = pessoa.id;
  delete from public.case_people where case_id = pessoa.case_id and person_id = pessoa.id;
  delete from public.people where id = pessoa.id;

  insert into public.management_audit(actor_id, target_id, action)
    values (eu, pessoa.id, 'nif_migrado_do_agregado');

  return jsonb_build_object('rendimentos', rendimentos, 'documentos', movidos);
end $$;

commit;
