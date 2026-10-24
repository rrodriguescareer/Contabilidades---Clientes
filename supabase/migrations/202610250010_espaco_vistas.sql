-- Uma vista, uma ida à base de dados.
--
-- Antes, cada separador do portal disparava entre quatro e onze pedidos ao
-- PostgREST. Com as funções do Vercel em arn1 e o Supabase em eu-north-1 isso
-- ainda custava pouco, mas o custo multiplicava-se por cada mudança de
-- separador. Estas funções devolvem o ecrã inteiro num único JSON.
--
-- São `security invoker`: a autorização continua a ser feita pelas políticas de
-- RLS já existentes, não por verificações repetidas aqui dentro.

begin;

create or replace function public.espaco_irs(vista text, processo uuid default null)
returns jsonb language plpgsql stable as $$
declare conta uuid; eu uuid := auth.uid(); dados jsonb := '{}'::jsonb;
begin
  if eu is null then raise exception 'Autenticação necessária' using errcode='42501'; end if;

  if processo is not null then
    -- A RLS decide o que é visível. Se não vier nada, o processo não é desta conta.
    select account_id into conta from public.irs_cases where id = processo;
    if conta is null then raise exception 'Processo indisponível' using errcode='42501'; end if;
  end if;

  if processo is null then return jsonb_build_object('vista', vista); end if;

  if vista = 'resumo' then
    dados := jsonb_build_object(
      'pessoas', (select count(*) from public.case_people where case_id = processo),
      'rendimentos', (select count(*) from public.income_records where case_id = processo and category <> 'deduction'),
      'despesas', (select count(*) from public.income_records where case_id = processo and category = 'deduction'),
      'documentos', (select count(*) from public.documents where case_id = processo and state <> 'pending'),
      'mensagens', (select count(*) from public.messages where case_id = processo),
      'ultimo_progresso', (select to_jsonb(p) from (
        select title, body, created_at from public.progress_events
        where case_id = processo order by created_at desc limit 1) p),
      'ultima_mensagem', (select to_jsonb(m) from (
        select body, author_id = eu as minha, created_at from public.messages
        where case_id = processo order by created_at desc limit 1) m),
      'pagamento', (select to_jsonb(c) from (
        select id, state, amount_cents, paid_at, created_at from public.irs_checkouts
        where case_id = processo order by created_at desc limit 1) c));

  elsif vista = 'agregado' then
    dados := jsonb_build_object(
      'pessoas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.ordem, p.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, pe.birth_date, pe.nif, pe.email, pe.tax_two_factor,
               cp.relationship,
               case cp.relationship when 'titular' then 0 when 'conjuge' then 1
                 when 'descendente' then 2 when 'ascendente' then 3 else 4 end as ordem
        from public.people pe
        join public.case_people cp on cp.person_id = pe.id and cp.case_id = processo) p),
      'disponiveis', (select coalesce(jsonb_agg(to_jsonb(d) order by d.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, pe.nif from public.people pe
        where pe.account_id = conta
          and not exists (select 1 from public.case_people cp where cp.case_id = processo and cp.person_id = pe.id)) d),
      'convites', (select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at desc), '[]'::jsonb) from (
        select id, person_id, email, state, expires_at, accepted_at, created_at
        from public.household_invitations where account_id = conta) i));

  elsif vista = 'rendimentos' then
    dados := jsonb_build_object(
      'rendimentos', (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]'::jsonb) from (
        select i.id, i.title, i.category, i.person_id, i.property_id, i.mode, i.details, i.created_at,
               (select count(*) from public.documents d where d.income_id = i.id and d.state <> 'pending') as documentos
        from public.income_records i where i.case_id = processo) r),
      'imoveis', (select coalesce(jsonb_agg(to_jsonb(v) order by v.label), '[]'::jsonb) from (
        select id, label, description from public.property_assets where case_id = processo) v),
      'pessoas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.full_name), '[]'::jsonb) from (
        select pe.id, pe.full_name, cp.relationship from public.people pe
        join public.case_people cp on cp.person_id = pe.id and cp.case_id = processo) p));

  elsif vista = 'documentos' then
    dados := jsonb_build_object(
      'documentos', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc), '[]'::jsonb) from (
        select dc.id, dc.kind, dc.file_name, dc.state, dc.income_id, dc.file_size, dc.mime_type, dc.created_at,
               dc.uploaded_by = eu as meu, i.title as rendimento, i.category
        from public.documents dc
        left join public.income_records i on i.id = dc.income_id
        where dc.case_id = processo and dc.state <> 'pending') d),
      'rendimentos', (select coalesce(jsonb_agg(to_jsonb(r) order by r.title), '[]'::jsonb) from (
        select id, title, category from public.income_records where case_id = processo) r));

  elsif vista = 'mensagens' then
    -- Sem nomes: o cliente não lê o perfil do contabilista nem o contrário.
    -- Cada lado sabe quem é o outro pelo contexto do ecrã.
    dados := jsonb_build_object(
      'mensagens', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) from (
        select id, body, author_id = eu as minha, created_at
        from public.messages where case_id = processo
        order by created_at desc limit 200) m));

  elsif vista = 'progresso' then
    dados := jsonb_build_object(
      'eventos', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from (
        select id, title, body, created_at from public.progress_events
        where case_id = processo order by created_at desc limit 100) p));

  elsif vista = 'pagamento' then
    dados := jsonb_build_object(
      'tentativas', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) from (
        select id, state, amount_cents, discount_cents, quote, checkout_url, paid_at, created_at
        from public.irs_checkouts where case_id = processo order by created_at desc limit 20) c),
      'faturas', (select coalesce(jsonb_agg(to_jsonb(f) order by f.issued_at desc), '[]'::jsonb) from (
        select i.id, i.reference, i.issued_at, i.due_at, i.total, i.currency,
               coalesce((select sum(p.amount) from public.payments p where p.invoice_id = i.id), 0) as pago
        from public.invoices i where i.account_id = conta) f));

  else
    raise exception 'Vista desconhecida: %', vista using errcode='22023';
  end if;

  return dados || jsonb_build_object('vista', vista, 'processo', processo);
end $$;

revoke all on function public.espaco_irs(text, uuid) from public, anon;
grant execute on function public.espaco_irs(text, uuid) to authenticated;


-- Ecrã do contabilista. A mesma ideia, mas atravessa todos os clientes.
create or replace function public.espaco_gabinete(vista text, processo uuid default null)
returns jsonb language plpgsql stable as $$
declare eu uuid := auth.uid();
begin
  if eu is null or not public.is_staff() then
    raise exception 'Apenas o contabilista acede a este espaço' using errcode='42501';
  end if;

  if vista = 'fila' then
    return jsonb_build_object('vista', vista,
      'processos', (select coalesce(jsonb_agg(to_jsonb(p) order by p.ordem, p.created_at), '[]'::jsonb) from (
        select c.id, c.account_id, c.status, c.created_at, a.name as cliente,
               case c.status when 'review' then 0 when 'validation' then 1 when 'authorization' then 2
                 when 'missing' then 3 when 'collecting' then 4 when 'submitted' then 5 else 6 end as ordem,
               (select count(*) from public.documents d where d.case_id = c.id and d.state = 'uploaded') as por_rever,
               (select count(*) from public.messages m where m.case_id = c.id and m.author_id <> eu) as mensagens_cliente,
               (select max(m.created_at) from public.messages m where m.case_id = c.id) as ultima_mensagem,
               (select x.state from public.irs_checkouts x where x.case_id = c.id order by x.created_at desc limit 1) as pagamento
        from public.irs_cases c join public.client_accounts a on a.id = c.account_id
        where c.campaign = 2026) p),
      'resumo', jsonb_build_object(
        'total', (select count(*) from public.irs_cases where campaign = 2026),
        'a_rever', (select count(*) from public.irs_cases where campaign = 2026 and status in ('review','validation','authorization')),
        'em_recolha', (select count(*) from public.irs_cases where campaign = 2026 and status = 'collecting'),
        'submetidos', (select count(*) from public.irs_cases where campaign = 2026 and status in ('submitted','completed')),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null)));

  elsif vista = 'alertas' then
    return jsonb_build_object('vista', vista,
      'alertas', (select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc), '[]'::jsonb) from (
        select t.id, t.kind, t.created_at, p.full_name as pessoa, c.name as cliente, t.account_id
        from public.task_alerts t
        join public.people p on p.id = t.person_id
        join public.client_accounts c on c.id = t.account_id
        where t.resolved_at is null) a));

  else
    -- Qualquer outra vista é a vista do cliente, vista de fora.
    return public.espaco_irs(vista, processo);
  end if;
end $$;

revoke all on function public.espaco_gabinete(text, uuid) from public, anon;
grant execute on function public.espaco_gabinete(text, uuid) to authenticated;

commit;
