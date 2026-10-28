-- Três falhas que o cliente via como "não gravou".
--
-- 1. Os documentos ficavam pendentes para sempre. O ficheiro chegava ao
--    Storage, mas o passo seguinte (marcar como enviado, com o separador, o
--    imóvel e a descrição) era recusado: o cliente só pode atualizar a coluna
--    state. O documento ficava 'pending', não aparecia em nenhum separador do
--    gabinete e bloqueava o pagamento. A conclusão passa para uma função que
--    confirma que o ficheiro chegou.
-- 2. As fotografias são guardadas em WebP, mas a preparação só aceitava PDF,
--    JPEG e PNG. Repetir o envio do mesmo ficheiro depois de uma falha também
--    era recusado; agora retoma-se.
-- 3. A senha das Finanças estava guardada, mas o espaço do cliente lê como o
--    cliente e a tabela das senhas só deixa ler o gabinete: dizia sempre "por
--    indicar".
begin;

create or replace function public.prepare_irs_document(
  account uuid, process uuid, record uuid, doc_kind text, original_name text,
  mime text, size_bytes bigint, hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare existing public.documents; document_id uuid := gen_random_uuid(); path text; reuse boolean := false;
begin
  if not public.can_edit_case(account, process) then raise exception 'Not authorized' using errcode = '42501'; end if;
  if hash is null or hash !~ '^[a-f0-9]{64}$'
     or mime not in ('application/pdf','image/jpeg','image/png','image/webp')
     or size_bytes is null or size_bytes not between 1 and 10485760 then
    raise exception 'Invalid file';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(account::text || process::text || hash, 0));

  -- Um envio que ficou a meio, da mesma pessoa: retoma-se no mesmo sítio.
  select * into existing from public.documents
   where account_id = account and case_id = process and content_hash = hash
     and state = 'pending' and uploaded_by = auth.uid()
   order by created_at desc limit 1;
  if found then
    if not exists(select 1 from storage.objects o
                   where o.bucket_id = 'irs-documents' and o.name = existing.storage_path) then
      update public.documents
         set kind = doc_kind, income_id = record, file_name = original_name,
             mime_type = mime, file_size = size_bytes
       where id = existing.id;
    end if;
    return jsonb_build_object('id', existing.id, 'path', existing.storage_path, 'reused', false, 'retomado', true);
  end if;

  select * into existing from public.documents
   where account_id = account and case_id = process and content_hash = hash
   order by (state in ('uploaded','reviewed')) desc, created_at limit 1;
  if found then
    if existing.state not in ('uploaded','reviewed') then
      raise exception 'Identical file pending or rejected. Contact the professional.';
    end if;
    if existing.file_size <> size_bytes or existing.mime_type <> mime then raise exception 'File metadata mismatch'; end if;
    path := existing.storage_path; reuse := true;
  else
    path := account::text || '/' || process::text || '/' || document_id::text;
  end if;
  insert into public.documents(id, account_id, case_id, income_id, kind, file_name, storage_path, mime_type, file_size, content_hash)
  values (document_id, account, process, record, doc_kind, original_name, path, mime, size_bytes, hash);
  return jsonb_build_object('id', document_id, 'path', path, 'reused', reuse);
end $$;

/* Concluir o envio: só quem o começou, só com o ficheiro já no Storage, e
   com o separador, o imóvel e a descrição validados aqui. Repetir é inócuo. */
create or replace function public.concluir_documento(
  p_documento uuid, p_categoria text, p_imovel uuid, p_descricao text)
returns void language plpgsql security definer set search_path = '' as $$
declare doc public.documents; descricao text := nullif(btrim(coalesce(p_descricao, '')), '');
begin
  select * into doc from public.documents where id = p_documento for update;
  if not found or doc.uploaded_by is distinct from auth.uid() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if doc.state in ('uploaded','reviewed') then return; end if;
  if doc.state <> 'pending' then raise exception 'Document not pending' using errcode = '22023'; end if;
  if not public.can_edit_case(doc.account_id, doc.case_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists(select 1 from storage.objects o
                 where o.bucket_id = 'irs-documents' and o.name = doc.storage_path) then
    raise exception 'File not received' using errcode = '22023';
  end if;
  if p_imovel is not null and not exists(
       select 1 from public.property_assets pa
        where pa.id = p_imovel and pa.account_id = doc.account_id and pa.case_id = doc.case_id) then
    raise exception 'Invalid property' using errcode = '22023';
  end if;
  update public.documents
     set state = 'uploaded',
         category = nullif(p_categoria, ''),
         property_id = p_imovel,
         description = case when length(descricao) >= 3 then left(descricao, 200) end
   where id = doc.id;
end $$;
revoke all on function public.concluir_documento(uuid, text, uuid, text) from public, anon;
grant execute on function public.concluir_documento(uuid, text, uuid, text) to authenticated;

/* Quando foi guardada a senha de uma pessoa. A senha cifrada não sai daqui. */
create or replace function public.senha_guardada_em(p_pessoa uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select tc.updated_at from public.tax_credentials tc
   where tc.person_id = p_pessoa and public.can_read_account(tc.account_id)
$$;
revoke all on function public.senha_guardada_em(uuid) from public, anon;
grant execute on function public.senha_guardada_em(uuid) to authenticated;

-- O espaço do cliente: a senha lida pela função acima, e os envios a meio
-- deixam de contar como documentos.
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.espaco_irs(text,uuid)'::regprocedure);
  if position('public.senha_guardada_em(' in d) > 0 then return; end if;
  d := replace(d, '''tem_senha'', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),',
                  '''tem_senha'', public.senha_guardada_em(p.id) is not null,');
  d := replace(d, '''senha_em'', (select tc.updated_at from public.tax_credentials tc where tc.person_id = p.id),',
                  '''senha_em'', public.senha_guardada_em(p.id),');
  d := replace(d, 'from public.documents d where d.case_id = processo)',
                  'from public.documents d where d.case_id = processo and d.state <> ''pending'')');
  d := replace(d, '(select count(*) from public.documents where case_id = processo)',
                  '(select count(*) from public.documents where case_id = processo and state <> ''pending'')');
  if position('tax_credentials' in d) > 0 then raise exception 'espaco_irs: ficou uma leitura direta das senhas'; end if;
  execute d;

  d := pg_get_functiondef('public.espaco_progresso(uuid)'::regprocedure);
  d := replace(d, '(select count(*) from public.documents where case_id = processo)',
                  '(select count(*) from public.documents where case_id = processo and state <> ''pending'')');
  execute d;

  d := pg_get_functiondef('public.prontidao_do_processo(uuid)'::regprocedure);
  d := replace(d, 'select count(*) into documentos from public.documents where case_id = processo;',
                  'select count(*) into documentos from public.documents where case_id = processo and state <> ''pending'';');
  execute d;

  -- Só trava o pagamento um envio em curso. Um que ficou a meio há mais de
  -- quinze minutos foi abandonado e não pode prender o processo.
  d := pg_get_functiondef('public.begin_irs_checkout(uuid,uuid,text,integer)'::regprocedure);
  d := replace(d, 'where case_id = process and state = ''pending'') then',
                  'where case_id = process and state = ''pending'' and created_at > now() - interval ''15 minutes'') then');
  if position('interval ''15 minutes''' in d) = 0 then raise exception 'begin_irs_checkout: condição dos envios não encontrada'; end if;
  execute d;
end $x$;

commit;
