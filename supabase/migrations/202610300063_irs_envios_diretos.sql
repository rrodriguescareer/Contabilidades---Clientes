-- O portal do IRS passa também a enviar os documentos do browser diretamente
-- para o Storage (o Vercel recusa pedidos com mais de 4,5 MB: um PDF
-- digitalizado ou uma fotografia de telemóvel já não passavam).
--
-- Como o ficheiro deixa de passar pelo servidor, a conclusão confirma no
-- próprio Storage o que lá chegou: o tipo tem de ser o anunciado e o tamanho
-- guardado passa a ser o real (nunca mais de 10 MB).
begin;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.concluir_documento(uuid,text,uuid,text)'::regprocedure);
  d := replace(d, $a$declare doc public.documents;$a$,
                  $a$declare doc public.documents; real_tamanho bigint; real_mime text;$a$);
  d := replace(d, $a$  if not exists(select 1 from storage.objects o
                 where o.bucket_id = 'irs-documents' and o.name = doc.storage_path) then
    raise exception 'File not received' using errcode = '22023';
  end if;$a$, $a$  select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
    into real_tamanho, real_mime
    from storage.objects o where o.bucket_id = 'irs-documents' and o.name = doc.storage_path;
  if not found then
    raise exception 'File not received' using errcode = '22023';
  end if;
  if real_mime is distinct from doc.mime_type or real_tamanho is null or real_tamanho not between 1 and 10485760 then
    raise exception 'File does not match' using errcode = '22023';
  end if;$a$);
  d := replace(d, $a$     set state = 'uploaded',$a$, $a$     set state = 'uploaded', file_size = real_tamanho,$a$);
  if d not like '%File does not match%' or d not like '%file_size = real_tamanho%' or d not like '%real_mime text%' then
    raise exception 'concluir_documento: texto não encontrado';
  end if;
  execute d;
end $x$;

commit;
