-- Plataforma Clientes Empresa (portal.rr-contabilidade.com).
--
-- Os clientes de contabilidade organizada entram com a mesma conta das outras
-- plataformas e veem só as empresas a que estão ligados em company_users, e só
-- se tiverem o acesso Empresas ligado (account_access.business, definido em
-- definir_acessos). O contabilista vê todas.
--
-- 1. Data de corte por empresa. Os saldos e os balancetes só saem até ela:
--    um balancete entregue ao banco tem de ser de um período já revisto. A
--    data fica na empresa e cada alteração fica no histórico.
-- 2. Documentos do mês, até ao dia 10 do mês seguinte (hora de Lisboa). O
--    envio é em dois tempos, como no IRS: a linha nasce pendente, o ficheiro
--    sobe para o Storage privado, e só depois a linha passa a recebida — e é
--    aí que se decide se chegou fora de prazo.
-- 3. Mensagens com o gabinete, prazos (por empresa ou para todas) e um
--    registo de atividade por empresa, que só o servidor e estas funções
--    escrevem.
-- 4. Cache das respostas do Cegid, só para o servidor. A chave inclui a data
--    de corte: mudar a data invalida tudo o que estava guardado.
--
-- Todas as funções novas: sem execute para public/anon; a autorização é
-- verificada dentro de cada uma.
begin;

-- ------------------------------------------------------------ data de corte
alter table public.companies
  add column data_corte date,
  add column data_corte_em timestamptz,
  add column data_corte_por uuid;

create table public.empresa_cortes (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  data_corte date,
  nota text check (nota is null or length(nota) <= 500),
  definido_por uuid not null,
  definido_em timestamptz not null default now()
);
create index empresa_cortes_empresa on public.empresa_cortes(company_id, definido_em desc);

-- ------------------------------------------------------------------ acesso
create function public.pode_aceder_empresa(empresa uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_staff() or (
    public.user_enabled((select auth.uid()))
    and exists (
      select 1 from public.account_access a
      join public.client_accounts ca on ca.id = a.account_id
      where a.user_id = (select auth.uid()) and a.business and a.active and ca.status = 'active')
    and exists (
      select 1 from public.company_users cu
      join public.companies c on c.id = cu.company_id
      where cu.company_id = empresa and cu.user_id = (select auth.uid()) and cu.active and c.active))
$$;

-- O fim do prazo dos documentos de um mês: o início do dia 11 do mês
-- seguinte, em Lisboa. Quem envia no dia 10 às 23h59 ainda está a tempo.
create function public.prazo_documentos(mes date) returns timestamptz
language sql stable set search_path = '' as $$
  select ((date_trunc('month', mes)::date + interval '1 month' + interval '10 days')::timestamp
          at time zone 'Europe/Lisbon')
$$;

create function public.mes_lisboa() returns date
language sql stable set search_path = '' as $$
  select date_trunc('month', (now() at time zone 'Europe/Lisbon'))::date
$$;

-- ---------------------------------------------------------------- atividade
create table public.empresa_atividade (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid,
  tipo text not null check (length(tipo) between 1 and 60),
  detalhe text check (detalhe is null or length(detalhe) <= 2000),
  ip text check (ip is null or length(ip) <= 100),
  agente text check (agente is null or length(agente) <= 400),
  criado_em timestamptz not null default now()
);
create index empresa_atividade_empresa on public.empresa_atividade(company_id, criado_em desc);

create function public.registar_empresa(empresa uuid, tipo text, detalhe text) returns void
language sql security definer set search_path = '' as $$
  insert into public.empresa_atividade(company_id, user_id, tipo, detalhe)
  values (empresa, auth.uid(), tipo, left(detalhe, 2000))
$$;

-- --------------------------------------------------------------- documentos
create table public.empresa_documentos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  categoria text not null check (categoria in ('vendas', 'compras', 'bancos', 'pessoal', 'outros')),
  nome text not null check (length(nome) between 1 and 220),
  caminho text not null unique,
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  tamanho bigint not null check (tamanho between 1 and 10485760),
  tamanho_original bigint check (tamanho_original is null or tamanho_original > 0),
  nota text check (nota is null or length(nota) <= 500),
  estado text not null default 'pendente' check (estado in ('pendente', 'recebido', 'visto', 'devolvido')),
  atrasado boolean not null default false,
  resposta text check (resposta is null or length(resposta) <= 1000),
  enviado_por uuid not null,
  criado_em timestamptz not null default now(),
  enviado_em timestamptz,
  revisto_em timestamptz,
  revisto_por uuid
);
create index empresa_documentos_mes on public.empresa_documentos(company_id, mes desc, criado_em desc);

create table public.empresa_meses (
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  completo_em timestamptz,
  completo_por uuid,
  conferido_em timestamptz,
  conferido_por uuid,
  nota text check (nota is null or length(nota) <= 1000),
  primary key (company_id, mes)
);

-- ---------------------------------------------------------------- mensagens
create table public.empresa_mensagens (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  autor_id uuid not null,
  do_gabinete boolean not null,
  corpo text not null check (length(btrim(corpo)) between 1 and 5000),
  criado_em timestamptz not null default now(),
  lida_em timestamptz
);
create index empresa_mensagens_empresa on public.empresa_mensagens(company_id, criado_em desc);

-- ------------------------------------------------------------------- prazos
create table public.empresa_prazos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  titulo text not null check (length(btrim(titulo)) between 1 and 200),
  descricao text check (descricao is null or length(descricao) <= 1000),
  data date not null,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_prazos_data on public.empresa_prazos(data);

-- ---------------------------------------------------------------- cache Cegid
create table public.empresa_cegid_cache (
  company_id uuid not null references public.companies(id) on delete cascade,
  chave text not null check (length(chave) <= 300),
  dados jsonb not null,
  obtido_em timestamptz not null default now(),
  primary key (company_id, chave)
);

-- ----------------------------------------------------------- permissões e RLS
alter table public.empresa_cortes enable row level security;
alter table public.empresa_atividade enable row level security;
alter table public.empresa_documentos enable row level security;
alter table public.empresa_meses enable row level security;
alter table public.empresa_mensagens enable row level security;
alter table public.empresa_prazos enable row level security;
alter table public.empresa_cegid_cache enable row level security;

revoke all on public.empresa_cortes, public.empresa_atividade, public.empresa_documentos, public.empresa_meses,
  public.empresa_mensagens, public.empresa_prazos, public.empresa_cegid_cache from anon, authenticated;
grant select on public.empresa_cortes, public.empresa_atividade, public.empresa_documentos, public.empresa_meses,
  public.empresa_mensagens, public.empresa_prazos to authenticated;
grant insert, delete on public.empresa_prazos to authenticated;
grant select, insert on public.empresa_atividade to service_role;
grant select, insert, update, delete on public.empresa_cegid_cache to service_role;

create policy empresa_cortes_ler on public.empresa_cortes for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_atividade_ler on public.empresa_atividade for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_documentos_ler on public.empresa_documentos for select to authenticated
  using (public.pode_aceder_empresa(company_id)
         and (estado <> 'pendente' or enviado_por = (select auth.uid())));
create policy empresa_meses_ler on public.empresa_meses for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_mensagens_ler on public.empresa_mensagens for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_prazos_ler on public.empresa_prazos for select to authenticated
  using ((select public.is_staff())
         or (company_id is null and exists (
               select 1 from public.company_users cu
               where cu.user_id = (select auth.uid()) and cu.active and public.pode_aceder_empresa(cu.company_id)))
         or (company_id is not null and public.pode_aceder_empresa(company_id)));
create policy empresa_prazos_criar on public.empresa_prazos for insert to authenticated
  with check ((select public.is_staff()) and criado_por = (select auth.uid()));
create policy empresa_prazos_apagar on public.empresa_prazos for delete to authenticated
  using ((select public.is_staff()));

-- ---------------------------------------------------------------- Storage
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('empresas-documentos', 'empresas-documentos', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy empresas_ficheiro_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and public.pode_aceder_empresa(d.company_id)
      and (d.estado <> 'pendente' or d.enviado_por = (select auth.uid()))));
create policy empresas_ficheiro_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and d.estado = 'pendente' and d.enviado_por = (select auth.uid())
      and public.pode_aceder_empresa(d.company_id)));
create policy empresas_ficheiro_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-documentos' and exists (
    select 1 from public.empresa_documentos d
    where d.caminho = name and d.estado in ('pendente', 'recebido')
      and (d.enviado_por = (select auth.uid()) or (select public.is_staff()))
      and public.pode_aceder_empresa(d.company_id)));

-- ---------------------------------------------------------------- funções

create function public.definir_data_corte(empresa uuid, corte date, nota text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then
    raise exception 'Apenas o contabilista define a data de corte' using errcode = '42501';
  end if;
  if corte is not null and corte > (now() at time zone 'Europe/Lisbon')::date then
    raise exception 'A data de corte não pode ser futura' using errcode = '22023';
  end if;
  if corte is not null and corte < date '2000-01-01' then
    raise exception 'Data de corte inválida' using errcode = '22023';
  end if;
  update public.companies
     set data_corte = corte, data_corte_em = now(), data_corte_por = auth.uid()
   where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_cortes(company_id, data_corte, nota, definido_por)
  values (empresa, corte, nullif(left(btrim(coalesce(nota, '')), 500), ''), auth.uid());
  delete from public.empresa_cegid_cache where company_id = empresa;
  perform public.registar_empresa(empresa, 'data_corte',
    case when corte is null then 'Data de corte retirada'
         else 'Data de corte: ' || to_char(corte, 'DD/MM/YYYY') end);
end $$;

create function public.preparar_documento_empresa(
  empresa uuid, mes date, categoria text, nome text, mime text,
  tamanho bigint, tamanho_original bigint default null, nota text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  eu uuid := auth.uid();
  atual date := public.mes_lisboa();
  novo uuid := gen_random_uuid();
  caminho text;
begin
  if eu is null or not public.user_enabled(eu) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > atual or mes < (atual - interval '24 months')::date then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente'
        and d.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  caminho := empresa::text || '/' || to_char(mes, 'YYYY-MM') || '/' || novo::text || '.' ||
    case mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg'
              when 'image/png' then 'png' when 'image/webp' then 'webp' else 'bin' end;
  insert into public.empresa_documentos(id, company_id, mes, categoria, nome, caminho, mime, tamanho,
                                        tamanho_original, nota, enviado_por)
  values (novo, empresa, mes, categoria, left(btrim(nome), 220), caminho, mime, tamanho, tamanho_original,
          nullif(left(btrim(coalesce(nota, '')), 500), ''), eu);
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create function public.concluir_documento_empresa(documento uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos; prazo timestamptz;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(d.company_id) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  prazo := public.prazo_documentos(d.mes);
  if d.estado <> 'pendente' then
    return jsonb_build_object('id', d.id, 'atrasado', d.atrasado, 'prazo', prazo, 'mes', d.mes);
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho) then
    raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
  end if;
  update public.empresa_documentos
     set estado = 'recebido', enviado_em = now(), atrasado = now() >= prazo
   where id = d.id;
  perform public.registar_empresa(d.company_id, case when now() >= prazo then 'documento_atrasado' else 'documento' end,
    'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') ||
    case when now() >= prazo then ' (fora do prazo)' else '' end);
  return jsonb_build_object('id', d.id, 'atrasado', now() >= prazo, 'prazo', prazo, 'mes', d.mes);
end $$;

create function public.eliminar_documento_empresa(documento uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or not public.pode_aceder_empresa(d.company_id)
     or (d.enviado_por is distinct from auth.uid() and not public.is_staff()) then
    raise exception 'Documento indisponível' using errcode = '42501';
  end if;
  if d.estado not in ('pendente', 'recebido') then
    raise exception 'Documento já revisto pelo contabilista' using errcode = '22023';
  end if;
  if d.estado = 'recebido' and exists (
       select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho) then
    raise exception 'Apague primeiro o ficheiro' using errcode = '22023';
  end if;
  delete from public.empresa_documentos where id = d.id;
  if d.estado = 'recebido' then
    perform public.registar_empresa(d.company_id, 'documento_eliminado',
      'Documento «' || d.nome || '» de ' || to_char(d.mes, 'MM/YYYY') || ' eliminado');
  end if;
end $$;

create function public.rever_documento_empresa(documento uuid, novo_estado text, resposta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista revê documentos' using errcode = '42501'; end if;
  if novo_estado not in ('recebido', 'visto', 'devolvido') then raise exception 'Estado inválido' using errcode = '22023'; end if;
  select * into d from public.empresa_documentos where id = documento for update;
  if not found or d.estado = 'pendente' then raise exception 'Documento indisponível' using errcode = '22023'; end if;
  update public.empresa_documentos
     set estado = novo_estado,
         resposta = nullif(left(btrim(coalesce(rever_documento_empresa.resposta, '')), 1000), ''),
         revisto_em = case when novo_estado = 'recebido' then null else now() end,
         revisto_por = case when novo_estado = 'recebido' then null else auth.uid() end
   where id = d.id;
  if novo_estado = 'devolvido' then
    perform public.registar_empresa(d.company_id, 'documento_devolvido',
      'Documento «' || d.nome || '» devolvido' || coalesce(': ' || nullif(btrim(rever_documento_empresa.resposta), ''), ''));
  end if;
end $$;

create function public.marcar_mes_completo(empresa uuid, mes date, completo boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > public.mes_lisboa() then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  insert into public.empresa_meses(company_id, mes, completo_em, completo_por)
  values (empresa, mes, case when completo then now() end, case when completo then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set completo_em = excluded.completo_em, completo_por = excluded.completo_por;
  perform public.registar_empresa(empresa, 'mes_completo',
    to_char(mes, 'MM/YYYY') || case when completo then ': documentação dada como completa' else ': reaberto para mais documentos' end);
end $$;

create function public.conferir_mes_empresa(empresa uuid, mes date, conferido boolean, nota text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista confere o mês' using errcode = '42501'; end if;
  if mes is null or mes <> date_trunc('month', mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  if not exists (select 1 from public.companies where id = empresa) then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_meses(company_id, mes, conferido_em, conferido_por, nota)
  values (empresa, mes, case when conferido then now() end, case when conferido then auth.uid() end,
          nullif(left(btrim(coalesce(nota, '')), 1000), ''))
  on conflict on constraint empresa_meses_pkey do update
    set conferido_em = excluded.conferido_em, conferido_por = excluded.conferido_por,
        nota = coalesce(excluded.nota, public.empresa_meses.nota);
  perform public.registar_empresa(empresa, 'mes_conferido',
    to_char(mes, 'MM/YYYY') || case when conferido then ': documentos conferidos pelo contabilista' else ': conferência anulada' end);
end $$;

create function public.enviar_mensagem_empresa(empresa uuid, corpo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare novo uuid;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if corpo is null or length(btrim(corpo)) not between 1 and 5000 then
    raise exception 'Mensagem vazia ou demasiado longa' using errcode = '22023';
  end if;
  insert into public.empresa_mensagens(company_id, autor_id, do_gabinete, corpo)
  values (empresa, auth.uid(), public.is_staff(), btrim(corpo)) returning id into novo;
  return novo;
end $$;

-- Marca como lidas as mensagens do outro lado. Devolve quantas.
create function public.ler_mensagens_empresa(empresa uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  update public.empresa_mensagens set lida_em = now()
   where company_id = empresa and lida_em is null and do_gabinete <> public.is_staff();
  get diagnostics n = row_count;
  return n;
end $$;

-- O contexto do portal, numa só ida: quem é, e que empresas vê.
create function public.portal_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare eu uuid := auth.uid(); staff boolean; perfil public.profiles; acesso record;
begin
  if eu is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into perfil from public.profiles where id = eu;
  staff := public.is_staff();
  select coalesce(bool_or(a.business and a.active and ca.status = 'active'), false) as empresas,
         coalesce(bool_or(a.irs and a.active and ca.status = 'active'), false) as irs
    into acesso
    from public.account_access a join public.client_accounts ca on ca.id = a.account_id
   where a.user_id = eu;
  return jsonb_build_object(
    'id', eu,
    'email', coalesce(perfil.email, (select email from auth.users where id = eu)),
    'nome', nullif(btrim(coalesce(perfil.full_name, '')), ''),
    'is_staff', staff,
    'ativo', public.user_enabled(eu),
    'acesso_empresas', staff or coalesce(acesso.empresas, false),
    'acesso_irs', coalesce(acesso.irs, false),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte,
               'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text))
             order by c.name)
        from public.companies c
       where c.active and public.pode_aceder_empresa(c.id)), '[]'::jsonb));
end $$;

-- A visão geral de uma empresa, numa só ida.
create function public.empresa_resumo(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.companies;
  staff boolean := public.is_staff();
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  -- O mês cujos documentos estão a ser pedidos agora: até dia 10, o anterior.
  em_curso date;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  select * into c from public.companies where id = empresa;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  return jsonb_build_object(
    'empresa', jsonb_build_object(
      'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'data_corte_em', c.data_corte_em,
      'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text)),
    'hoje', hoje,
    'mes_em_curso', em_curso,
    'meses', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'mes', m.mes,
               'prazo', public.prazo_documentos(m.mes),
               'documentos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado <> 'pendente'),
               'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.atrasado and d.estado <> 'pendente'),
               'devolvidos', (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.mes = m.mes and d.estado = 'devolvido'),
               'completo_em', em.completo_em,
               'conferido_em', em.conferido_em) order by m.mes desc), '[]'::jsonb)
        from (select (atual - make_interval(months => g))::date as mes from generate_series(0, 5) g) m
        left join public.empresa_meses em on em.company_id = empresa and em.mes = m.mes),
    'mensagens_por_ler', (
      select count(*) from public.empresa_mensagens m
       where m.company_id = empresa and m.lida_em is null and m.do_gabinete <> staff),
    'ultima_mensagem', (
      select jsonb_build_object('corpo', left(m.corpo, 280), 'em', m.criado_em, 'do_gabinete', m.do_gabinete)
        from public.empresa_mensagens m where m.company_id = empresa order by m.criado_em desc limit 1),
    'prazos', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'titulo', p.titulo, 'data', p.data,
                                                   'descricao', p.descricao, 'geral', p.company_id is null)
                                order by p.data), '[]'::jsonb)
        from (select * from public.empresa_prazos p
               where (p.company_id = empresa or p.company_id is null) and p.data >= hoje
               order by p.data limit 6) p),
    'atividade', (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'detalhe', a.detalhe, 'em', a.criado_em)
                                order by a.criado_em desc), '[]'::jsonb)
        from (select * from public.empresa_atividade a where a.company_id = empresa
               order by a.criado_em desc limit 8) a));
end $$;

-- A lista da gestão: o estado de cada empresa, numa só ida.
create function public.gestao_empresas() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  em_curso date;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  return jsonb_build_object(
    'mes_em_curso', em_curso,
    'prazo', public.prazo_documentos(em_curso),
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'data_corte', c.data_corte,
        'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text),
        'documentos', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.estado <> 'pendente'),
        'por_ver', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.estado = 'recebido'),
        'atrasados', (select count(*) from public.empresa_documentos d where d.company_id = c.id and d.mes = em_curso and d.atrasado and d.estado <> 'pendente'),
        'completo', (select em.completo_em is not null from public.empresa_meses em where em.company_id = c.id and em.mes = em_curso),
        'mensagens', (select count(*) from public.empresa_mensagens m where m.company_id = c.id and m.lida_em is null and not m.do_gabinete)))
        from public.companies c), '[]'::jsonb));
end $$;

-- ------------------------------------------------------- execute das funções
do $x$
declare f text;
begin
  foreach f in array array[
    'public.pode_aceder_empresa(uuid)', 'public.prazo_documentos(date)', 'public.mes_lisboa()',
    'public.definir_data_corte(uuid,date,text)', 'public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)',
    'public.concluir_documento_empresa(uuid)', 'public.eliminar_documento_empresa(uuid)',
    'public.rever_documento_empresa(uuid,text,text)', 'public.marcar_mes_completo(uuid,date,boolean)',
    'public.conferir_mes_empresa(uuid,date,boolean,text)', 'public.enviar_mensagem_empresa(uuid,text)',
    'public.ler_mensagens_empresa(uuid)', 'public.portal_empresas()', 'public.empresa_resumo(uuid)',
    'public.gestao_empresas()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;
-- O registo interno só é chamado pelas funções acima.
revoke all on function public.registar_empresa(uuid, text, text) from public, anon, authenticated;

commit;
