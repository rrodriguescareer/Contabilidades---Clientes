-- Preços por regras.
--
-- Até aqui a tabela de preços tinha dez valores com regras fixas no código.
-- Passa a ser uma lista de regras, cada uma com:
--   rótulo, valor, condições (todas têm de se cumprir), cobrança por unidade
--   (por imóvel, por pessoa…), e as regras que anula quando se aplica.
-- Cada política é uma versão imutável: editar é criar outra a partir dela.
-- O histórico guarda quando cada uma esteve em vigor, e qualquer uma pode
-- voltar a vigorar. Há um mínimo e um máximo opcionais por política.
--
-- As regras de hoje passam a ser as regras por omissão (regras_padrao), com os
-- mesmos valores e o mesmo resultado.
begin;

alter table public.pricing_policies
  add column regras jsonb check (regras is null or jsonb_typeof(regras) = 'array'),
  add column minimo_cents integer check (minimo_cents is null or minimo_cents >= 0),
  add column maximo_cents integer check (maximo_cents is null or maximo_cents >= 0),
  add column origem uuid references public.pricing_policies(id) on delete set null;

create table public.pricing_historico (
  id bigint generated always as identity primary key,
  policy_id uuid not null references public.pricing_policies(id) on delete cascade,
  ativada_em timestamptz not null default now(),
  ativada_por uuid,
  desativada_em timestamptz
);
create index pricing_historico_politica on public.pricing_historico(policy_id, ativada_em desc);
alter table public.pricing_historico enable row level security;
revoke all on public.pricing_historico from anon, authenticated;
grant select on public.pricing_historico to authenticated;
create policy pricing_historico_gabinete on public.pricing_historico for select to authenticated using ((select public.is_staff()));
create policy dois_fatores on public.pricing_historico as restrictive for all to authenticated
  using ((select public.aal_suficiente())) with check ((select public.aal_suficiente()));

/* As regras de sempre, a partir dos dez valores antigos. */
create function public.regras_padrao(v jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_array(
    jsonb_build_object('id', 'base', 'ordem', 10, 'rotulo', 'Preparação IRS — primeiro tipo de rendimento (IVA incluído)',
      'valor_cents', coalesce((v->>'base')::int, 1850), 'condicoes', '[]'::jsonb),
    jsonb_build_object('id', 'household_work', 'ordem', 20, 'rotulo', 'Várias pessoas com trabalho ou pensões',
      'valor_cents', coalesce((v->>'varios_titulares')::int, 500),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'contagem', 'medida', 'pessoas_trabalho', 'min', 2))),
    jsonb_build_object('id', 'a_and_b', 'ordem', 30, 'rotulo', 'Acumulação de categorias A e B',
      'valor_cents', coalesce((v->>'a_e_b')::int, 1500), 'anula', jsonb_build_array('additional_b'),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'categoria', 'modo', 'todas', 'categorias', jsonb_build_array('employment', 'independent')))),
    jsonb_build_object('id', 'additional_b', 'ordem', 40, 'rotulo', 'Categoria B adicional às pensões',
      'valor_cents', coalesce((v->>'b_adicional')::int, 500),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'categoria', 'modo', 'todas', 'categorias', jsonb_build_array('pension', 'independent')))),
    jsonb_build_object('id', 'rents_only', 'ordem', 50, 'rotulo', 'Rendas — {n} imóvel(is)',
      'valor_cents', coalesce((v->>'rendas_unica')::int, 0), 'anula', jsonb_build_array('rents_2'),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'contagem', 'medida', 'imoveis_renda', 'min', 1, 'max', 2),
                                     jsonb_build_object('tipo', 'contagem', 'medida', 'tipos_rendimento', 'max', 1))),
    jsonb_build_object('id', 'rents_2', 'ordem', 51, 'rotulo', 'Rendas — {n} imóvel(is)',
      'valor_cents', coalesce((v->>'rendas_ate2')::int, 500),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'contagem', 'medida', 'imoveis_renda', 'min', 1, 'max', 2))),
    jsonb_build_object('id', 'rents_5', 'ordem', 52, 'rotulo', 'Rendas — {n} imóvel(is)',
      'valor_cents', coalesce((v->>'rendas_ate5')::int, 1000),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'contagem', 'medida', 'imoveis_renda', 'min', 3, 'max', 5))),
    jsonb_build_object('id', 'rents_more', 'ordem', 53, 'rotulo', 'Rendas — {n} imóvel(is)',
      'valor_cents', coalesce((v->>'rendas_mais')::int, 2000),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'contagem', 'medida', 'imoveis_renda', 'min', 6))),
    jsonb_build_object('id', 'securities', 'ordem', 60, 'rotulo', 'Mais-valias de ações e outros títulos — categoria G',
      'valor_cents', coalesce((v->>'mais_valias_titulos')::int, 1000),
      'condicoes', jsonb_build_array(jsonb_build_object('tipo', 'categoria', 'modo', 'alguma', 'categorias', jsonb_build_array('securities')))),
    jsonb_build_object('id', 'property_sales', 'ordem', 70, 'rotulo', 'Mais-valias de imóveis — {n} imóvel(is)',
      'valor_cents', coalesce((v->>'mais_valias_imovel')::int, 1000),
      'por_unidade', jsonb_build_object('medida', 'imoveis_venda', 'acima_de', 0), 'condicoes', '[]'::jsonb))
$$;

/* O que um processo tem, nas medidas que as regras usam. */
create function public.medidas_do_processo(account uuid, process uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'categorias', coalesce((select jsonb_agg(distinct ir.category) from public.income_records ir
                             where ir.account_id = account and ir.case_id = process and ir.category <> 'deduction'), '[]'::jsonb),
    'tipos_rendimento', (select count(distinct ir.category) from public.income_records ir
                          where ir.account_id = account and ir.case_id = process and ir.category <> 'deduction'),
    'rendimentos', (select count(*) from public.income_records ir where ir.account_id = account and ir.case_id = process),
    'pessoas_trabalho', (select count(distinct ir.person_id) from public.income_records ir
                          where ir.account_id = account and ir.case_id = process and ir.category in ('employment', 'pension')),
    'imoveis_renda', (select count(distinct ir.property_id) from public.income_records ir
                       where ir.account_id = account and ir.case_id = process and ir.category = 'property_rent'),
    'imoveis_venda', (select count(distinct ir.property_id) from public.income_records ir
                       where ir.account_id = account and ir.case_id = process and ir.category = 'property_sale'),
    'membros', (select count(*) from public.case_people cp where cp.case_id = process),
    'dependentes', (select count(*) from public.case_people cp where cp.case_id = process and cp.relationship = 'descendente'))
$$;
revoke all on function public.medidas_do_processo(uuid, uuid) from public, anon, authenticated;

/* O motor. Puro: as mesmas regras e medidas dão sempre o mesmo preço.
   1. Uma regra aplica-se quando está ativa e todas as condições se cumprem.
   2. Pela ordem: uma regra anulada por outra que já entrou fica de fora; e
      uma regra que entra tira as que já tinham entrado e que ela anula.
   3. Por unidade: valor × (medida − «acima de»); com zero unidades não entra.
   4. Mínimo e máximo da política, como linhas de ajuste. */
create function public.preco_por_regras(regras jsonb, m jsonb, minimo integer default null, maximo integer default null)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  r jsonb; c jsonb; ok boolean; n integer; tipo text; modo text;
  cats text[]; tem text[] := array(select jsonb_array_elements_text(coalesce(m->'categorias', '[]'::jsonb)));
  aplicaveis jsonb[] := '{}'; incluidas jsonb[] := '{}'; novas jsonb[]; i jsonb;
  unidades integer; medida integer; valor integer; total integer := 0; items jsonb := '[]'::jsonb;
begin
  for r in select x.value from jsonb_array_elements(coalesce(regras, '[]'::jsonb)) with ordinality x(value, posicao)
            order by coalesce((x.value->>'ordem')::int, 1000), x.posicao loop
    if not coalesce((r->>'ativa')::boolean, true) then continue; end if;
    ok := true;
    for c in select value from jsonb_array_elements(coalesce(r->'condicoes', '[]'::jsonb)) loop
      tipo := c->>'tipo';
      if tipo = 'categoria' then
        cats := array(select jsonb_array_elements_text(coalesce(c->'categorias', '[]'::jsonb)));
        modo := coalesce(c->>'modo', 'alguma');
        if modo = 'alguma' and not (cats && tem) then ok := false;
        elsif modo = 'todas' and not (cats <@ tem) then ok := false;
        elsif modo = 'nenhuma' and (cats && tem) then ok := false;
        end if;
      elsif tipo = 'contagem' then
        n := coalesce((m->>(c->>'medida'))::int, 0);
        if c->>'min' is not null and n < (c->>'min')::int then ok := false; end if;
        if c->>'max' is not null and n > (c->>'max')::int then ok := false; end if;
      else
        ok := false; -- uma condição desconhecida nunca se cumpre
      end if;
      exit when not ok;
    end loop;
    if ok then aplicaveis := aplicaveis || r; end if;
  end loop;

  foreach r in array aplicaveis loop
    if exists (select 1 from unnest(incluidas) j where coalesce(j->'anula', '[]'::jsonb) ? (r->>'id')) then continue; end if;
    novas := '{}';
    foreach i in array incluidas loop
      if not (coalesce(r->'anula', '[]'::jsonb) ? (i->>'id')) then novas := novas || i; end if;
    end loop;
    incluidas := novas || r;
  end loop;

  foreach r in array incluidas loop
    unidades := 1; medida := null;
    if jsonb_typeof(r->'por_unidade') = 'object' then
      medida := coalesce((m->>(r->'por_unidade'->>'medida'))::int, 0);
      unidades := greatest(0, medida - coalesce((r->'por_unidade'->>'acima_de')::int, 0));
      if unidades = 0 then continue; end if;
    else
      select coalesce((m->>(x.value->>'medida'))::int, 0) into medida
        from jsonb_array_elements(coalesce(r->'condicoes', '[]'::jsonb)) x where x.value->>'tipo' = 'contagem' limit 1;
    end if;
    valor := coalesce((r->>'valor_cents')::int, 0) * unidades;
    items := items || jsonb_build_array(jsonb_build_object(
      'code', r->>'id', 'label', replace(coalesce(r->>'rotulo', ''), '{n}', coalesce(medida::text, '')),
      'amount_cents', valor, 'unidades', unidades));
    total := total + valor;
  end loop;

  if minimo is not null and total < minimo then
    items := items || jsonb_build_array(jsonb_build_object('code', 'minimo', 'label', 'Ajuste ao valor mínimo', 'amount_cents', minimo - total));
    total := minimo;
  end if;
  if maximo is not null and total > maximo then
    items := items || jsonb_build_array(jsonb_build_object('code', 'maximo', 'label', 'Limite máximo do serviço', 'amount_cents', maximo - total));
    total := maximo;
  end if;
  return jsonb_build_object('items', items, 'subtotal_cents', total);
end $$;

/* As regras são validadas antes de se gravarem: ids únicos e simples,
   valores em cêntimos, condições e medidas conhecidas, anulações para regras
   que existem. Devolve o primeiro problema, ou nulo. */
create function public.problema_nas_regras(regras jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare r jsonb; c jsonb; ids text[] := '{}'; a text;
  medidas text[] := array['tipos_rendimento', 'rendimentos', 'pessoas_trabalho', 'imoveis_renda', 'imoveis_venda', 'membros', 'dependentes'];
  categorias text[] := array['employment', 'pension', 'independent', 'property_sale', 'securities', 'property_rent', 'foreign_income', 'other'];
begin
  if regras is null or jsonb_typeof(regras) <> 'array' or jsonb_array_length(regras) = 0 then return 'A política precisa de pelo menos uma regra.'; end if;
  if jsonb_array_length(regras) > 60 then return 'No máximo 60 regras.'; end if;
  for r in select value from jsonb_array_elements(regras) loop
    if coalesce(r->>'id', '') !~ '^[a-z0-9_-]{1,40}$' then return 'Cada regra precisa de um código simples (letras minúsculas, números, - e _).'; end if;
    if r->>'id' = any(ids) then return 'Há duas regras com o código «' || (r->>'id') || '».'; end if;
    ids := ids || (r->>'id');
    if length(btrim(coalesce(r->>'rotulo', ''))) not between 1 and 160 then return 'A regra «' || (r->>'id') || '» precisa de um rótulo.'; end if;
    if jsonb_typeof(r->'valor_cents') <> 'number' or (r->>'valor_cents')::numeric not between 0 and 10000000
       or (r->>'valor_cents')::numeric <> trunc((r->>'valor_cents')::numeric) then
      return 'O valor da regra «' || (r->>'id') || '» é inválido.';
    end if;
    for c in select value from jsonb_array_elements(coalesce(r->'condicoes', '[]'::jsonb)) loop
      if c->>'tipo' = 'categoria' then
        if coalesce(c->>'modo', 'alguma') not in ('alguma', 'todas', 'nenhuma') or jsonb_typeof(c->'categorias') <> 'array'
           or jsonb_array_length(c->'categorias') = 0
           or exists (select 1 from jsonb_array_elements_text(c->'categorias') x where x <> all(categorias)) then
          return 'Uma condição de rendimentos da regra «' || (r->>'id') || '» é inválida.';
        end if;
      elsif c->>'tipo' = 'contagem' then
        if coalesce(c->>'medida', '') <> all(medidas)
           or (c->>'min' is not null and (c->>'min') !~ '^\d{1,4}$') or (c->>'max' is not null and (c->>'max') !~ '^\d{1,4}$') then
          return 'Uma condição de quantidade da regra «' || (r->>'id') || '» é inválida.';
        end if;
      else
        return 'A regra «' || (r->>'id') || '» tem uma condição desconhecida.';
      end if;
    end loop;
    if r->'por_unidade' is not null and jsonb_typeof(r->'por_unidade') = 'object'
       and (coalesce(r->'por_unidade'->>'medida', '') <> all(medidas) or coalesce(r->'por_unidade'->>'acima_de', '0') !~ '^\d{1,4}$') then
      return 'A cobrança por unidade da regra «' || (r->>'id') || '» é inválida.';
    end if;
  end loop;
  for r in select value from jsonb_array_elements(regras) loop
    for a in select jsonb_array_elements_text(coalesce(r->'anula', '[]'::jsonb)) loop
      if a <> all(ids) or a = r->>'id' then return 'A regra «' || (r->>'id') || '» anula uma regra que não existe.'; end if;
    end loop;
  end loop;
  return null;
end $$;

/* Simular: as regras (as gravadas ou as que se estão a editar) sobre um
   processo imaginado. Só para o gabinete. */
create function public.simular_preco(regras jsonb, medidas jsonb, minimo integer default null, maximo integer default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare problema text;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  problema := public.problema_nas_regras(regras);
  if problema is not null then return jsonb_build_object('erro', problema); end if;
  return public.preco_por_regras(regras, medidas, minimo, maximo);
end $$;

/* Gravar uma política nova (uma versão). Nunca altera uma que já existe. */
create function public.criar_politica_precos(p_nome text, p_regras jsonb, p_notas text default null, p_minimo integer default null,
  p_maximo integer default null, p_origem uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare problema text; novo uuid;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_nome, ''))) not between 2 and 120 then raise exception 'Dê um nome à política.' using errcode = '22023'; end if;
  problema := public.problema_nas_regras(p_regras);
  if problema is not null then raise exception '%', problema using errcode = '22023'; end if;
  if p_minimo is not null and p_maximo is not null and p_minimo > p_maximo then
    raise exception 'O mínimo não pode ser maior do que o máximo.' using errcode = '22023';
  end if;
  insert into public.pricing_policies(nome, activa, valores, regras, notas, minimo_cents, maximo_cents, origem, criada_por)
  values (btrim(p_nome), false, '{}'::jsonb, p_regras, left(btrim(coalesce(p_notas, '')), 500), p_minimo, p_maximo, p_origem, auth.uid())
  returning id into novo;
  return novo;
end $$;

/* Pôr uma política em vigor (também uma antiga: é assim que se recupera). */
create function public.ativar_politica_precos(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  if not exists (select 1 from public.pricing_policies where id = p_id) then raise exception 'Política desconhecida' using errcode = '22023'; end if;
  update public.pricing_historico set desativada_em = now() where desativada_em is null;
  update public.pricing_policies set activa = false where activa and id <> p_id;
  update public.pricing_policies set activa = true where id = p_id;
  insert into public.pricing_historico(policy_id, ativada_por) values (p_id, auth.uid());
end $$;

/* O preço de um processo: as regras da política em vigor (ou as de sempre). */
create or replace function public.price_irs_case(account uuid, process uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  politica public.pricing_policies;
  m jsonb;
  regras jsonb;
  r jsonb;
begin
  if not public.can_read_account(account)
     or not exists(select 1 from public.irs_cases c where c.id = process and c.account_id = account) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  m := public.medidas_do_processo(account, process);
  if coalesce((m->>'tipos_rendimento')::int, 0) = 0 then
    raise exception 'Add at least one income type' using errcode = '22023';
  end if;
  select * into politica from public.pricing_policies where activa limit 1;
  regras := coalesce(politica.regras, public.regras_padrao(coalesce(politica.valores, public.precos_em_vigor())));
  r := public.preco_por_regras(regras, m, politica.minimo_cents, politica.maximo_cents);
  return jsonb_build_object(
    'version', '2026-11-01.regras', 'currency', 'EUR', 'items', r->'items',
    'subtotal_cents', (r->>'subtotal_cents')::int, 'vat_included', true,
    'politica', politica.id, 'politica_nome', politica.nome);
end $$;

do $x$
declare f text;
begin
  foreach f in array array['public.simular_preco(jsonb,jsonb,integer,integer)',
    'public.criar_politica_precos(text,jsonb,text,integer,integer,uuid)', 'public.ativar_politica_precos(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;
revoke all on function public.regras_padrao(jsonb), public.preco_por_regras(jsonb, jsonb, integer, integer),
  public.problema_nas_regras(jsonb) from public, anon;
grant execute on function public.regras_padrao(jsonb), public.preco_por_regras(jsonb, jsonb, integer, integer),
  public.problema_nas_regras(jsonb) to authenticated, service_role;

commit;
