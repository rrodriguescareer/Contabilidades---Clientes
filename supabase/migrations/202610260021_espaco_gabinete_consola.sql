-- A consola do contabilista não é o espelho do cliente.
-- O cliente navega um processo de cada vez; o contabilista precisa da fila
-- toda de uma vez e, quando abre um processo, de tudo junto no mesmo pedido.
begin;

create or replace function public.espaco_gabinete(vista text, processo uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  dados jsonb := jsonb_build_object('vista', vista, 'processo', processo);
begin
  if not public.is_staff() then
    return dados || jsonb_build_object('erro', 'sem_acesso');
  end if;

  if vista = 'fila' then
    return dados || jsonb_build_object(
      'processos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id, 'cliente', a.name, 'estado', c.status, 'desde', c.status_changed_at,
          'submetido_em', c.submitted_by_client_at, 'ano', c.tax_year,
          'titulares', (select count(*) from public.case_people cp where cp.case_id = c.id),
          'rendimentos', (select count(*) from public.income_records ir where ir.case_id = c.id),
          'documentos', (select count(*) from public.documents d where d.case_id = c.id),
          'por_rever', (select count(*) from public.documents d
                         where d.case_id = c.id and d.state = 'uploaded'),
          'mensagens', (select count(*) from public.messages m where m.case_id = c.id),
          'dois_fatores', exists(select 1 from public.case_people cp
                                  join public.people p on p.id = cp.person_id
                                  where cp.case_id = c.id and p.tax_two_factor),
          'pago', exists(select 1 from public.irs_checkouts k
                          where k.case_id = c.id and k.state = 'paid')
        ) order by
          case c.status
            when 'submitted_by_client' then 0 when 'accepted' then 1
            when 'validation' then 2 when 'approved' then 3
            when 'submitting' then 4 when 'filed' then 5
            when 'monitoring' then 6 when 'collecting' then 7 else 8 end,
          c.status_changed_at), '[]'::jsonb)
        from public.irs_cases c
        join public.client_accounts a on a.id = c.account_id),
      'totais', jsonb_build_object(
        'abertos', (select count(*) from public.irs_cases where status <> 'closed'),
        'a_rever', (select count(*) from public.irs_cases
                     where status in ('submitted_by_client','accepted','validation')),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null))
    );
  end if;

  if vista = 'mensagens' then
    return dados || jsonb_build_object(
      'conversas', (
        select coalesce(jsonb_agg(x order by x->>'ultima' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
            'processo', c.id, 'cliente', a.name,
            'total', (select count(*) from public.messages m where m.case_id = c.id),
            'ultima', (select max(m.created_at) from public.messages m where m.case_id = c.id),
            'por_responder', exists(
              select 1 from public.messages m
              where m.case_id = c.id
                and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
                and m.created_at > coalesce((
                  select max(m2.created_at) from public.messages m2
                  join public.staff_users s2 on s2.user_id = m2.author_id
                  where m2.case_id = c.id), '-infinity'::timestamptz))
          ) as x
          from public.irs_cases c
          join public.client_accounts a on a.id = c.account_id
          where exists(select 1 from public.messages m where m.case_id = c.id)
        ) t)
    );
  end if;

  if vista = 'pagamentos' then
    return dados || jsonb_build_object(
      'pagamentos', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', k.id, 'processo', k.case_id, 'cliente', a.name,
          'estado', k.state, 'total', k.amount_cents, 'desconto', k.discount_cents,
          'criado', k.created_at, 'pago_em', k.paid_at
        ) order by k.created_at desc), '[]'::jsonb)
        from public.irs_checkouts k
        join public.client_accounts a on a.id = k.account_id)
    );
  end if;

  if vista = 'alertas' then
    return dados || jsonb_build_object(
      'alertas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', t.id, 'tipo', t.kind, 'em', t.created_at,
          'pessoa', p.full_name, 'cliente', a.name,
          'processo', (select c.id from public.irs_cases c
                        where c.account_id = t.account_id order by c.tax_year desc limit 1)
        ) order by t.created_at desc), '[]'::jsonb)
        from public.task_alerts t
        join public.client_accounts a on a.id = t.account_id
        left join public.people p on p.id = t.person_id
        where t.resolved_at is null)
    );
  end if;

  if processo is null then
    return dados || jsonb_build_object('erro', 'sem_processo');
  end if;

  return dados || jsonb_build_object(
    'cabecalho', (
      select jsonb_build_object(
        'cliente', a.name, 'conta', c.account_id,
        'estado', c.status, 'desde', c.status_changed_at,
        'ano', c.tax_year, 'submetido_em', c.submitted_by_client_at,
        'valor_final', c.final_amount_cents, 'sentido', c.final_direction,
        'nif', (select pr.nif from public.profiles pr
                 join public.account_access aa on aa.user_id = pr.id
                 where aa.account_id = c.account_id order by aa.role limit 1),
        'residencia', (select pr.tax_residence from public.profiles pr
                 join public.account_access aa on aa.user_id = pr.id
                 where aa.account_id = c.account_id order by aa.role limit 1))
      from public.irs_cases c
      join public.client_accounts a on a.id = c.account_id
      where c.id = processo),
    'membros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.full_name, 'nascimento', p.birth_date, 'nif', p.nif,
        'relacao', cp.relationship, 'dois_fatores', p.tax_two_factor,
        'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
        'consultas', (select count(*) from public.tax_credential_views v where v.person_id = p.id)
      ) order by case cp.relationship when 'titular' then 0 else 1 end, p.full_name), '[]'::jsonb)
      from public.case_people cp
      join public.people p on p.id = cp.person_id
      where cp.case_id = processo),
    'imoveis', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pa.id, 'nome', pa.label, 'tipo', pa.kind) order by pa.label), '[]'::jsonb)
      from public.property_assets pa where pa.case_id = processo),
    'rendimentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ir.id, 'categoria', ir.category, 'tipo', ir.kind, 'titulo', ir.title,
        'titular', ir.person_id, 'imovel', ir.property_id, 'valor', ir.amount_cents,
        'nota', ir.details, 'irs_jovem', ir.young_irs, 'estuda_trabalha', ir.studies_and_works,
        'ambito', ir.foreign_scope, 'compra_em', ir.acquired_on, 'venda_em', ir.sold_on,
        'compra', ir.acquisition_cents, 'venda', ir.sale_cents, 'despesas', ir.expenses_cents,
        'hpp', ir.hpp_reinvestment, 'hpp_credito', ir.hpp_credit_cents, 'hpp_feito', ir.hpp_done
      ) order by ir.category, ir.created_at), '[]'::jsonb)
      from public.income_records ir where ir.case_id = processo),
    'documentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'tipo', d.kind, 'descricao', d.description, 'categoria', d.category,
        'nome', d.file_name, 'tamanho', d.file_size, 'estado', d.state, 'em', d.created_at,
        'imovel', (select pa.label from public.property_assets pa where pa.id = d.property_id),
        'descargas', (select count(*) from public.document_downloads dd where dd.document_id = d.id)
      ) order by d.created_at desc), '[]'::jsonb)
      from public.documents d where d.case_id = processo),
    'notas', (
      select coalesce(jsonb_object_agg(cn.tab, cn.body), '{}'::jsonb)
      from public.case_notes cn where cn.case_id = processo),
    'deducoes', (
      select to_jsonb(cd) - 'case_id' - 'account_id'
      from public.case_deductions cd where cd.case_id = processo),
    'mensagens', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', m.id, 'corpo', m.body, 'em', m.created_at,
        'do_gabinete', exists(select 1 from public.staff_users s where s.user_id = m.author_id)
      ) order by m.created_at), '[]'::jsonb)
      from public.messages m where m.case_id = processo),
    'eventos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pe.id, 'titulo', pe.title, 'corpo', pe.body, 'em', pe.created_at
      ) order by pe.created_at desc), '[]'::jsonb)
      from public.progress_events pe where pe.case_id = processo),
    'checkout', (
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at)
      from public.irs_checkouts k where k.case_id = processo
      order by k.created_at desc limit 1)
  );
end $$;

commit;
