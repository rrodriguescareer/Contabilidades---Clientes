begin;
-- Originals stay in private object storage; Postgres stores only metadata and SHA-256.
alter table public.documents add column content_hash text check(content_hash ~ '^[a-f0-9]{64}$');
alter table public.documents drop constraint documents_storage_path_key,drop constraint documents_check;
alter table public.documents add constraint document_path_same_case check(
 storage_path ~ ('^'||account_id::text||'/'||case_id::text||'/[a-f0-9-]{36}$'));
create index documents_content_lookup on public.documents(account_id,case_id,content_hash);
create function public.prepare_irs_document(account uuid,process uuid,record uuid,doc_kind text,original_name text,mime text,size_bytes bigint,hash text)
 returns jsonb language plpgsql security definer set search_path='' as $$
declare existing public.documents; document_id uuid:=gen_random_uuid(); path text; reuse boolean:=false;
begin
 if not public.can_edit_case(account,process) then raise exception 'Not authorized' using errcode='42501';end if;
 if hash is null or hash !~ '^[a-f0-9]{64}$' or mime not in ('application/pdf','image/jpeg','image/png') or size_bytes is null or size_bytes not between 1 and 10485760 then raise exception 'Invalid file';end if;
 perform pg_advisory_xact_lock(hashtextextended(account::text||process::text||hash,0));
 select * into existing from public.documents where account_id=account and case_id=process and content_hash=hash order by (state in ('uploaded','reviewed')) desc,created_at limit 1;
 if found then
  if existing.state not in ('uploaded','reviewed') then raise exception 'Identical file pending or rejected. Contact the professional.';end if;
  if existing.file_size<>size_bytes or existing.mime_type<>mime then raise exception 'File metadata mismatch';end if;
  path:=existing.storage_path;reuse:=true;
 else path:=account::text||'/'||process::text||'/'||document_id::text;
 end if;
 insert into public.documents(id,account_id,case_id,income_id,kind,file_name,storage_path,mime_type,file_size,content_hash)
 values(document_id,account,process,record,doc_kind,original_name,path,mime,size_bytes,hash);
 return jsonb_build_object('id',document_id,'path',path,'reused',reuse);
end $$;
revoke all on function public.prepare_irs_document(uuid,uuid,uuid,text,text,text,bigint,text) from public,anon;
grant execute on function public.prepare_irs_document(uuid,uuid,uuid,text,text,text,bigint,text) to authenticated;
commit;
