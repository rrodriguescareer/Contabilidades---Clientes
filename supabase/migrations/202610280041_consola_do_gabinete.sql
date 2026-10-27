-- A consola do contabilista, refeita. Mantém todas as chaves que já existiam
-- (o relatório usa-as) e acrescenta o que faltava para trabalhar:
--   * na fila: NIF, contactos, mensagens por responder, estado do pagamento,
--     e totais por fase;
--   * no processo: contactos, morada, residência fiscal e a prontidão;
--   * consultar a senha das Finanças, com registo (o cliente vê-o);
--   * registar a descarga de um documento (o cliente vê-a).
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
          'nif', dono.nif, 'email', dono.email, 'telefone', dono.phone,
          'titulares', (select count(*) from public.case_people cp where cp.case_id = c.id),
          'rendimentos', (select count(*) from public.income_records ir where ir.case_id = c.id),
          'documentos', (select count(*) from public.documents d where d.case_id = c.id),
          'por_rever', (select count(*) from public.documents d
                         where d.case_id = c.id and d.state = 'uploaded'
                           and not exists(select 1 from public.document_downloads dd where dd.document_id = d.id)),
          'mensagens', (select count(*) from public.messages m where m.case_id = c.id),
          'por_responder', (
            select count(*) from public.messages m
             where m.case_id = c.id
               and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
               and m.created_at > coalesce((
                 select max(m2.created_at) from public.messages m2
                  join public.staff_users s2 on s2.user_id = m2.author_id
                  where m2.case_id = c.id), '-infinity'::timestamptz)),
          'dois_fatores', exists(select 1 from public.case_people cp
                                  join public.people p on p.id = cp.person_id
                                  where cp.case_id = c.id and p.tax_two_factor),
          'pago', exists(select 1 from public.irs_checkouts k
                          where k.case_id = c.id and k.state = 'paid'),
          'pagamento', (select k.state from public.irs_checkouts k where k.case_id = c.id
                         order by k.created_at desc limit 1),
          'total', (select k.amount_cents from public.irs_checkouts k where k.case_id = c.id
                     order by k.created_at desc limit 1)
        ) order by
          case c.status
            when 'submitted_by_client' then 0 when 'divergence' then 1 when 'accepted' then 2
            when 'validation' then 3 when 'approved' then 4 when 'submitting' then 5
            when 'returned' then 6 when 'filed' then 7 when 'monitoring' then 8
            when 'assessed' then 9 when 'collecting' then 10 else 11 end,
          c.status_changed_at), '[]'::jsonb)
        from public.irs_cases c
        join public.client_accounts a on a.id = c.account_id
        left join lateral (
          select pr.nif, pr.email, pr.phone from public.profiles pr
            join public.account_access aa on aa.user_id = pr.id
           where aa.account_id = c.account_id and aa.role = 'owner'
           limit 1) dono on true),
      'totais', jsonb_build_object(
        'abertos', (select count(*) from public.irs_cases where status <> 'closed'),
        'a_rever', (select count(*) from public.irs_cases
                     where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
        'recolha', (select count(*) from public.irs_cases where status in ('collecting','returned')),
        'entregues', (select count(*) from public.irs_cases where status in ('filed','monitoring','assessed','closed')),
        'pagos', (select count(*) from public.irs_checkouts where state = 'paid'),
        'receita', (select coalesce(sum(amount_cents), 0) from public.irs_checkouts where state = 'paid'),
        'alertas', (select count(*) from public.task_alerts where resolved_at is null),
        'por_responder', (
          select count(distinct m.case_id) from public.messages m
           where not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
             and m.created_at > coalesce((
               select max(m2.created_at) from public.messages m2
                join public.staff_users s2 on s2.user_id = m2.author_id
                where m2.case_id = m.case_id), '-infinity'::timestamptz)))
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
            'resumo', (select left(m.body, 140) from public.messages m where m.case_id = c.id
                        order by m.created_at desc limit 1),
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
        join public.client_accounts a on a.id = k.account_id
        where k.state <> 'cancelled')
    );
  end if;

  if vista = 'alertas' then
    return dados || jsonb_build_object(
      'alertas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', t.id, 'tipo', t.kind, 'em', t.created_at,
          'pessoa', p.full_name, 'cliente', a.name, 'conta', t.account_id,
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
        'nif', dono.nif, 'residencia', dono.tax_residence,
        'email', dono.email, 'telefone', dono.phone, 'morada', dono.address,
        'representante', case when dono.rep_name is null then null else jsonb_build_object(
          'nome', dono.rep_name, 'nif', dono.rep_nif, 'email', dono.rep_email, 'telefone', dono.rep_phone) end)
      from public.irs_cases c
      join public.client_accounts a on a.id = c.account_id
      left join lateral (
        select pr.* from public.profiles pr
          join public.account_access aa on aa.user_id = pr.id
         where aa.account_id = c.account_id and aa.role = 'owner'
         limit 1) dono on true
      where c.id = processo),
    'membros', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.full_name, 'nascimento', p.birth_date, 'nif', p.nif,
        'relacao', cp.relationship, 'dois_fatores', p.tax_two_factor,
        'tem_senha', exists(select 1 from public.tax_credentials tc where tc.person_id = p.id),
        'consultas', (select count(*) from public.tax_credential_views v where v.person_id = p.id),
        'ultima_consulta', (select max(v.viewed_at) from public.tax_credential_views v where v.person_id = p.id)
      ) order by case cp.relationship when 'titular' then 0 else 1 end, p.full_name), '[]'::jsonb)
      from public.case_people cp
      join public.people p on p.id = cp.person_id
      where cp.case_id = processo),
    'imoveis', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pa.id, 'nome', pa.label, 'tipo', pa.kind, 'descricao', pa.description) order by pa.label), '[]'::jsonb)
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
      select jsonb_build_object('estado', k.state, 'total', k.amount_cents, 'pago_em', k.paid_at,
                                'desconto', k.discount_cents, 'detalhe', k.quote)
      from public.irs_checkouts k where k.case_id = processo and k.state <> 'cancelled'
      order by k.created_at desc limit 1),
    'prontidao', public.prontidao_do_processo(processo)
  );
end $$;

-- A senha das Finanças, para mim. Fica registado quem, quando e de quem —
-- é esse registo que o cliente vê no Acompanhamento.
create or replace function public.consultar_senha_financas(p_pessoa uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare guardada public.tax_credentials;
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into guardada from public.tax_credentials where person_id = p_pessoa;
  if not found then
    raise exception 'Esta pessoa não tem senha guardada.' using errcode = '22023';
  end if;
  insert into public.tax_credential_views(person_id, account_id, viewed_by)
    values (p_pessoa, guardada.account_id, auth.uid());
  return guardada.encrypted_password;
end $$;

revoke all on function public.consultar_senha_financas(uuid) from public, anon;
grant execute on function public.consultar_senha_financas(uuid) to authenticated;

-- A descarga de um documento por mim, registada.
create or replace function public.registar_descarga(documento uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare doc public.documents;
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into doc from public.documents where id = documento;
  if not found or doc.state not in ('uploaded','reviewed') then
    raise exception 'Documento indisponível.' using errcode = '22023';
  end if;
  insert into public.document_downloads(document_id, account_id, downloaded_by)
    values (doc.id, doc.account_id, auth.uid());
  return doc.storage_path;
end $$;

revoke all on function public.registar_descarga(uuid) from public, anon;
grant execute on function public.registar_descarga(uuid) to authenticated;

commit;
