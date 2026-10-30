-- Os ficheiros passam a ir do browser diretamente para o Storage.
--
-- Até aqui, os documentos subiam pelo servidor da aplicação, e o Vercel
-- recusa qualquer pedido com mais de 4,5 MB: três fotografias de telemóvel já
-- não passavam. Agora o servidor só regista o envio e pede ao Storage um
-- endereço de carregamento assinado; o browser envia o ficheiro para lá.
--
-- 1. Como o ficheiro já não passa pelo servidor, a conclusão confirma no
--    próprio Storage o que lá chegou: o tipo tem de ser o anunciado e o
--    tamanho passa a ser o real (nunca mais de 10 MB).
-- 2. Os envios que ficaram a meio (o browser fechou antes de carregar) saem
--    sozinhos: quem prepara um envio novo limpa os seus registos pendentes com
--    mais de seis horas e sem ficheiro.
begin;

create or replace function public.concluir_documento_empresa(documento uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos; prazo timestamptz; real_tamanho bigint; real_mime text;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(d.company_id) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  prazo := public.prazo_documentos(d.mes);
  if d.estado <> 'pendente' then
    return jsonb_build_object('id', d.id, 'atrasado', d.atrasado, 'prazo', prazo, 'mes', d.mes);
  end if;
  select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
    into real_tamanho, real_mime
    from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho;
  if not found then
    raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
  end if;
  if real_mime is distinct from d.mime or real_tamanho is null or real_tamanho not between 1 and 10485760 then
    raise exception 'O ficheiro recebido não corresponde ao anunciado' using errcode = '22023';
  end if;
  update public.empresa_documentos
     set estado = 'recebido', enviado_em = now(), atrasado = now() >= prazo, tamanho = real_tamanho
   where id = d.id;
  perform public.registar_empresa(d.company_id, case when now() >= prazo then 'documento_atrasado' else 'documento' end,
    'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') ||
    case when now() >= prazo then ' (fora do prazo)' else '' end);
  return jsonb_build_object('id', d.id, 'atrasado', now() >= prazo, 'prazo', prazo, 'mes', d.mes);
end $$;

create or replace function public.concluir_ficheiro_empresa(ficheiro uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros; real_tamanho bigint; real_mime text;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or f.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(f.company_id) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if f.estado = 'pendente' then
    select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1)
      into real_tamanho, real_mime
      from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho;
    if not found then
      raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
    end if;
    if real_mime is distinct from f.mime or real_tamanho is null or real_tamanho not between 1 and 10485760 then
      raise exception 'O ficheiro recebido não corresponde ao anunciado' using errcode = '22023';
    end if;
    update public.empresa_ficheiros set estado = 'carregado', carregado_em = now(), tamanho = real_tamanho where id = f.id;
    if f.contexto = 'recibos' then
      update public.empresa_recibos set publicado_em = now(), publicado_por = auth.uid() where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'recibos', 'Recibos de vencimento publicados');
    elsif f.contexto = 'comprovativo' then
      update public.empresa_impostos set estado = 'pago', pago_em = coalesce(pago_em, now()), pago_por = coalesce(pago_por, auth.uid())
       where id = f.ref_id;
      perform public.registar_empresa(f.company_id, 'imposto', 'Comprovativo de pagamento enviado: ' || f.nome);
    elsif f.contexto = 'guia' then
      perform public.registar_empresa(f.company_id, 'imposto', 'Guia de pagamento publicada: ' || f.nome);
    end if;
  end if;
  return jsonb_build_object('id', f.id, 'contexto', f.contexto, 'ref', f.ref_id);
end $$;

-- A limpeza dos envios a meio, nas duas funções que os começam.
do $x$
declare d text;
begin
  d := pg_get_functiondef('public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)'::regprocedure);
  d := replace(d, $a$  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'$a$,
$a$  delete from public.empresa_documentos d
   where d.enviado_por = eu and d.estado = 'pendente' and d.criado_em < now() - interval '6 hours'
     and not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho);
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'$a$);
  if d not like '%interval ''6 hours''%' then raise exception 'preparar_documento_empresa: texto não encontrado'; end if;
  execute d;

  d := pg_get_functiondef('public.preparar_ficheiro_empresa(uuid,text,uuid,text,text,bigint)'::regprocedure);
  d := replace(d, $a$  caminho := empresa::text || '/' || p_contexto$a$,
$a$  delete from public.empresa_ficheiros f
   where f.enviado_por = auth.uid() and f.estado = 'pendente' and f.criado_em < now() - interval '6 hours'
     and not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho);
  if (select count(*) from public.empresa_ficheiros f where f.company_id = empresa and f.estado = 'pendente'
        and f.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  caminho := empresa::text || '/' || p_contexto$a$);
  if d not like '%interval ''6 hours''%' then raise exception 'preparar_ficheiro_empresa: texto não encontrado'; end if;
  execute d;
end $x$;

revoke all on function public.concluir_documento_empresa(uuid) from public, anon;
revoke all on function public.concluir_ficheiro_empresa(uuid) from public, anon;
grant execute on function public.concluir_documento_empresa(uuid) to authenticated, service_role;
grant execute on function public.concluir_ficheiro_empresa(uuid) to authenticated, service_role;

commit;
