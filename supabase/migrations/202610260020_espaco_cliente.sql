-- O espaço do cliente: um separador, um pedido.
-- A função corre com as permissões de quem chama (security invoker), por isso
-- é a RLS que decide o que cada um vê — não há aqui nenhuma verificação de
-- acesso à mão que possa divergir das políticas.
begin;

create or replace function public.espaco_irs(vista text, processo uuid default null)  -- o default existia: tirá-lo obriga a DROP
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  conta uuid;
  dados jsonb := jsonb_build_object('vista', vista, 'processo', processo);
  membros jsonb;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null then
    return dados || jsonb_build_object('erro', 'sem_acesso');
  end if;

  -- O agregado serve de base a quase tudo: os rendimentos escolhem titular,
  -- as deduções escolhem o titular do PPR.
  select coalesce(jsonb_agg(m order by m->>'ordem', m->>'nome'), '[]'::jsonb) into membros
  from (
    select jsonb_build_object(
      'id', p.id,
      'nome', p.full_name,
      'nascimento', p.birth_date,
      'nif', p.nif,
      'email', p.email,
      'relacao', cp.relationship,
      'dois_fatores', p.tax_two_factor,
      'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
      'senha_em', (select tc.updated_at from public.tax_credentials tc where tc.person_id = p.id),
      'ordem', case cp.relationship when 'titular' then '0' else '1' end
    ) as m
    from public.case_people cp
    join public.people p on p.id = cp.person_id
    where cp.case_id = processo
  ) t;

  if vista = 'agregado' then
    return dados || jsonb_build_object('membros', membros);
  end if;

  if vista = 'rendimentos' then
    return dados || jsonb_build_object(
      'membros', membros,
      'imoveis', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', pa.id, 'nome', pa.label, 'tipo', pa.kind, 'descricao', pa.description
        ) order by pa.label), '[]'::jsonb)
        from public.property_assets pa where pa.case_id = processo),
      'rendimentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', ir.id, 'categoria', ir.category, 'tipo', ir.kind, 'titulo', ir.title,
          'titular', ir.person_id, 'imovel', ir.property_id, 'valor', ir.amount_cents,
          'nota', ir.details, 'irs_jovem', ir.young_irs, 'estuda_trabalha', ir.studies_and_works,
          'ambito', ir.foreign_scope,
          'compra_em', ir.acquired_on, 'venda_em', ir.sold_on,
          'compra', ir.acquisition_cents, 'venda', ir.sale_cents, 'despesas', ir.expenses_cents,
          'hpp', ir.hpp_reinvestment, 'hpp_credito', ir.hpp_credit_cents, 'hpp_feito', ir.hpp_done
        ) order by ir.created_at), '[]'::jsonb)
        from public.income_records ir where ir.case_id = processo),
      'notas', (
        select coalesce(jsonb_object_agg(cn.tab, cn.body), '{}'::jsonb)
        from public.case_notes cn where cn.case_id = processo),
      'deducoes', (
        select to_jsonb(cd) - 'case_id' - 'account_id'
        from public.case_deductions cd where cd.case_id = processo),
      'documentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
          'imovel', d.property_id, 'rendimento', d.income_id, 'nome', d.file_name,
          'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at
        ) order by d.created_at desc), '[]'::jsonb)
        from public.documents d where d.case_id = processo)
    );
  end if;

  if vista = 'documentos' then
    return dados || jsonb_build_object(
      'documentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
          'nome', d.file_name, 'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at,
          'imovel', (select pa.label from public.property_assets pa where pa.id = d.property_id),
          'descargas', (
            select coalesce(jsonb_agg(dd.downloaded_at order by dd.downloaded_at desc), '[]'::jsonb)
            from public.document_downloads dd where dd.document_id = d.id)
        ) order by d.created_at desc), '[]'::jsonb)
        from public.documents d where d.case_id = processo)
    );
  end if;

  if vista = 'progresso' then
    return dados || jsonb_build_object(
      'processo', (
        select jsonb_build_object(
          'estado', c.status, 'desde', c.status_changed_at,
          'submetido_em', c.submitted_by_client_at,
          'valor_final', c.final_amount_cents, 'sentido', c.final_direction)
        from public.irs_cases c where c.id = processo),
      'eventos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
        ) order by pe.created_at desc), '[]'::jsonb)
        from public.progress_events pe where pe.case_id = processo),
      -- O cliente vê quando é que a senha dele foi consultada, e de quem.
      'consultas_senha', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'pessoa', p.full_name, 'em', v.viewed_at
        ) order by v.viewed_at desc), '[]'::jsonb)
        from public.tax_credential_views v
        join public.people p on p.id = v.person_id
        where v.account_id = conta)
    );
  end if;

  if vista = 'mensagens' then
    return dados || jsonb_build_object(
      'mensagens', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', m.id, 'corpo', m.body, 'em', m.created_at, 'autor', m.author_id,
          'do_gabinete', exists(select 1 from public.staff_users s where s.user_id = m.author_id)
        ) order by m.created_at), '[]'::jsonb)
        from public.messages m where m.case_id = processo)
    );
  end if;

  if vista = 'pagamento' then
    return dados || jsonb_build_object(
      'processo', (
        select jsonb_build_object('estado', c.status, 'rotulo', c.label, 'ano', c.tax_year)
        from public.irs_cases c where c.id = processo),
      'checkout', (
        select jsonb_build_object(
          'id', k.id, 'estado', k.state, 'total', k.amount_cents,
          'desconto', k.discount_cents, 'detalhe', k.quote,
          'url', k.checkout_url, 'pago_em', k.paid_at)
        from public.irs_checkouts k
        where k.case_id = processo order by k.created_at desc limit 1)
    );
  end if;

  -- resumo
  return dados || jsonb_build_object(
    'membros', membros,
    'processo', (
      select jsonb_build_object('estado', c.status, 'desde', c.status_changed_at, 'ano', c.tax_year)
      from public.irs_cases c where c.id = processo),
    'contagens', jsonb_build_object(
      'rendimentos', (select count(*) from public.income_records where case_id = processo),
      'documentos', (select count(*) from public.documents where case_id = processo),
      'mensagens', (select count(*) from public.messages where case_id = processo))
  );
end $$;

commit;
