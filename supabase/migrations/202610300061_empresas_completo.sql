-- Portal Empresas, segunda volta.
--
-- 1. Definições da empresa (só o contabilista): mês de início do
--    acompanhamento (não há meses antes dele), meses bloqueados para envio e
--    meses fechados com a informação completa.
-- 2. Ficha da empresa (dados fiscais), editável pelo contabilista e pelo
--    cliente, com o histórico de cada alteração: quem, quando, de onde, o
--    valor antes e depois.
-- 3. Alertas do gabinete que aparecem no portal, com leitura por pessoa.
-- 4. Logótipo da empresa (WebP pequeno, Storage privado).
-- 5. Pessoal: comunicações de admissões, cessações, ausências e alterações,
--    tratadas pelo contabilista; e os recibos de vencimento de cada mês, um
--    PDF por mês.
-- 6. Impostos: períodos por tipo (IRC, IVA, IRS, Segurança Social, outros),
--    com guia, referência, valor e prazo; o cliente marca como pago e junta o
--    comprovativo.
-- 7. A cache do Cegid sai da base: passa para a cache de dados do Next, com
--    uma versão por empresa na chave. A tabela empresa_cegid_cache é apagada.
--
-- Funções novas: sem execute para public/anon; autorização dentro de cada uma.
begin;

-- ------------------------------------------------------------ empresa
alter table public.companies
  add column inicio date check (inicio is null or inicio = date_trunc('month', inicio)::date),
  add column logotipo_caminho text,
  add column logotipo_em timestamptz,
  add column cegid_versao integer not null default 0;

alter table public.empresa_meses
  add column bloqueado boolean not null default false,
  add column fechado_em timestamptz,
  add column fechado_por uuid;

-- O NIF português: nove algarismos e o dígito de controlo (módulo 11).
create function public.nif_valido(nif text) returns boolean
language sql immutable set search_path = '' as $$
  select case when coalesce(nif, '') !~ '^[1-9][0-9]{8}$' then false else (
    with d as (select substr(nif, i, 1)::int as v, i from generate_series(1, 9) i),
         s as (select sum(v * (10 - i)) as t from d where i <= 8)
    select case when 11 - (t % 11) >= 10 then 0 else 11 - (t % 11) end = (select v from d where i = 9) from s) end
$$;

-- ------------------------------------------------------------ ficha
create table public.empresa_fichas (
  company_id uuid primary key references public.companies(id) on delete cascade,
  forma_juridica text check (forma_juridica is null or length(forma_juridica) <= 100),
  cae text check (cae is null or cae ~ '^[0-9]{5}(\s*[,;]\s*[0-9]{5}){0,9}$'),
  regime_iva text check (regime_iva is null or regime_iva in ('mensal', 'trimestral', 'isento_53', 'outro')),
  regime_iva_outro text check (regime_iva_outro is null or length(regime_iva_outro) <= 200),
  tem_trabalhadores boolean not null default false,
  morada text check (morada is null or length(morada) <= 300),
  codigo_postal text check (codigo_postal is null or codigo_postal ~ '^[0-9]{4}-[0-9]{3}$'),
  localidade text check (localidade is null or length(localidade) <= 100),
  capital_social numeric(16, 2) check (capital_social is null or capital_social >= 0),
  representantes text check (representantes is null or length(representantes) <= 1000),
  niss text check (niss is null or niss ~ '^[0-9]{11}$'),
  iban text check (iban is null or iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'),
  email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  telefone text check (telefone is null or length(telefone) between 6 and 30),
  contacto_nome text check (contacto_nome is null or length(contacto_nome) <= 200),
  contacto_email text check (contacto_email is null or contacto_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contacto_telefone text check (contacto_telefone is null or length(contacto_telefone) between 6 and 30),
  atualizado_em timestamptz,
  atualizado_por uuid
);

create table public.empresa_ficha_historico (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  campo text not null,
  antes text,
  depois text,
  origem text not null check (origem in ('gestao', 'portal')),
  alterado_por uuid,
  alterado_em timestamptz not null default now()
);
create index empresa_ficha_historico_empresa on public.empresa_ficha_historico(company_id, alterado_em desc);

-- ------------------------------------------------------------ alertas
create table public.empresa_alertas (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade, -- nulo: todas as empresas
  titulo text not null check (length(btrim(titulo)) between 1 and 200),
  corpo text check (corpo is null or length(corpo) <= 2000),
  nivel text not null default 'info' check (nivel in ('info', 'aviso', 'urgente')),
  expira_em date,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_alertas_empresa on public.empresa_alertas(company_id, criado_em desc);
create table public.empresa_alertas_lidos (
  alerta_id uuid not null references public.empresa_alertas(id) on delete cascade,
  user_id uuid not null,
  lido_em timestamptz not null default now(),
  primary key (alerta_id, user_id)
);

-- ------------------------------------------------------------ pessoal
create table public.empresa_pessoal (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('admissao', 'cessacao', 'ausencia', 'alteracao')),
  trabalhador text not null check (length(btrim(trabalhador)) between 1 and 200),
  dados jsonb not null default '{}'::jsonb check (jsonb_typeof(dados) = 'object' and length(dados::text) <= 8000),
  estado text not null default 'novo' check (estado in ('novo', 'em_tratamento', 'tratado', 'devolvido')),
  resposta text check (resposta is null or length(resposta) <= 1000),
  criado_por uuid not null,
  criado_em timestamptz not null default now(),
  tratado_em timestamptz,
  tratado_por uuid
);
create index empresa_pessoal_empresa on public.empresa_pessoal(company_id, criado_em desc);

create table public.empresa_recibos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  mes date not null check (mes = date_trunc('month', mes)::date),
  publicado_em timestamptz,
  publicado_por uuid,
  descarregado_em timestamptz,
  unique (company_id, mes)
);

-- ------------------------------------------------------------ impostos
create table public.empresa_impostos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('IRC', 'IVA', 'IRS', 'SS', 'OUTROS')),
  periodo text not null check (length(btrim(periodo)) between 1 and 20),
  descricao text check (descricao is null or length(descricao) <= 300),
  referencia text check (referencia is null or length(referencia) <= 200),
  valor numeric(14, 2) check (valor is null or valor >= 0),
  prazo date,
  estado text not null default 'por_pagar' check (estado in ('por_pagar', 'pago')),
  pago_em timestamptz,
  pago_por uuid,
  criado_por uuid not null,
  criado_em timestamptz not null default now()
);
create index empresa_impostos_empresa on public.empresa_impostos(company_id, prazo);

-- ------------------------------------------------------------ ficheiros
-- Um só registo para os ficheiros destas secções: documentos do pessoal,
-- recibos de vencimento, guias de impostos e comprovativos de pagamento.
create table public.empresa_ficheiros (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contexto text not null check (contexto in ('pessoal', 'recibos', 'guia', 'comprovativo')),
  ref_id uuid not null,
  nome text not null check (length(nome) between 1 and 220),
  caminho text not null unique,
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  tamanho bigint not null check (tamanho between 1 and 10485760),
  estado text not null default 'pendente' check (estado in ('pendente', 'carregado')),
  enviado_por uuid not null,
  criado_em timestamptz not null default now(),
  carregado_em timestamptz
);
create index empresa_ficheiros_ref on public.empresa_ficheiros(ref_id);

-- ----------------------------------------------------------- RLS e permissões
alter table public.empresa_fichas enable row level security;
alter table public.empresa_ficha_historico enable row level security;
alter table public.empresa_alertas enable row level security;
alter table public.empresa_alertas_lidos enable row level security;
alter table public.empresa_pessoal enable row level security;
alter table public.empresa_recibos enable row level security;
alter table public.empresa_impostos enable row level security;
alter table public.empresa_ficheiros enable row level security;

revoke all on public.empresa_fichas, public.empresa_ficha_historico, public.empresa_alertas, public.empresa_alertas_lidos,
  public.empresa_pessoal, public.empresa_recibos, public.empresa_impostos, public.empresa_ficheiros from anon, authenticated;
grant select on public.empresa_fichas, public.empresa_ficha_historico, public.empresa_alertas, public.empresa_alertas_lidos,
  public.empresa_pessoal, public.empresa_recibos, public.empresa_impostos, public.empresa_ficheiros to authenticated;
grant insert, delete on public.empresa_alertas to authenticated;

create policy empresa_fichas_ler on public.empresa_fichas for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_ficha_historico_ler on public.empresa_ficha_historico for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_alertas_ler on public.empresa_alertas for select to authenticated
  using ((select public.is_staff())
         or (company_id is null and exists (
               select 1 from public.company_users cu
               where cu.user_id = (select auth.uid()) and cu.active and public.pode_aceder_empresa(cu.company_id)))
         or (company_id is not null and public.pode_aceder_empresa(company_id)));
create policy empresa_alertas_criar on public.empresa_alertas for insert to authenticated
  with check ((select public.is_staff()) and criado_por = (select auth.uid()));
create policy empresa_alertas_apagar on public.empresa_alertas for delete to authenticated
  using ((select public.is_staff()));
create policy empresa_alertas_lidos_ler on public.empresa_alertas_lidos for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_staff()));
create policy empresa_pessoal_ler on public.empresa_pessoal for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_recibos_ler on public.empresa_recibos for select to authenticated
  using (public.pode_aceder_empresa(company_id) and (publicado_em is not null or (select public.is_staff())));
create policy empresa_impostos_ler on public.empresa_impostos for select to authenticated
  using (public.pode_aceder_empresa(company_id));
create policy empresa_ficheiros_ler on public.empresa_ficheiros for select to authenticated
  using (public.pode_aceder_empresa(company_id) and (estado = 'carregado' or enviado_por = (select auth.uid())));

-- ------------------------------------------------------------ Storage
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('empresas-ficheiros', 'empresas-ficheiros', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']),
       ('empresas-logotipos', 'empresas-logotipos', false, 524288, array['image/webp', 'image/png'])
on conflict (id) do nothing;

create policy empresas_ficheiros_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and public.pode_aceder_empresa(f.company_id)
      and (f.estado = 'carregado' or f.enviado_por = (select auth.uid()))));
create policy empresas_ficheiros_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and f.estado = 'pendente' and f.enviado_por = (select auth.uid())
      and public.pode_aceder_empresa(f.company_id)));
create policy empresas_ficheiros_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-ficheiros' and exists (
    select 1 from public.empresa_ficheiros f
    where f.caminho = name and public.pode_aceder_empresa(f.company_id)
      and (f.enviado_por = (select auth.uid()) or (select public.is_staff()))));

-- O logótipo: <empresa>/logotipo-<número>.webp, de quem pode ver a empresa.
create function public.logotipo_da_empresa(caminho text) returns uuid
language sql immutable set search_path = '' as $$
  select case when caminho ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/logotipo-[0-9]{1,20}\.(webp|png)$'
              then split_part(caminho, '/', 1)::uuid end
$$;
create policy empresas_logotipo_ler on storage.objects for select to authenticated
  using (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));
create policy empresas_logotipo_inserir on storage.objects for insert to authenticated
  with check (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));
create policy empresas_logotipo_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'empresas-logotipos' and public.logotipo_da_empresa(name) is not null and public.pode_aceder_empresa(public.logotipo_da_empresa(name)));

-- ------------------------------------------------------------ funções

-- Definições: só o contabilista.
create function public.definir_inicio_empresa(empresa uuid, p_inicio date) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista define o início' using errcode = '42501'; end if;
  update public.companies set inicio = date_trunc('month', p_inicio)::date where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  perform public.registar_empresa(empresa, 'definicoes',
    case when p_inicio is null then 'Início do acompanhamento retirado'
         else 'Início do acompanhamento: ' || to_char(date_trunc('month', p_inicio), 'MM/YYYY') end);
end $$;

create function public.definir_mes_empresa(empresa uuid, p_mes date, p_bloqueado boolean, p_fechado boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista bloqueia ou fecha meses' using errcode = '42501'; end if;
  if p_mes is null or p_mes <> date_trunc('month', p_mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  if not exists (select 1 from public.companies where id = empresa) then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_meses(company_id, mes, bloqueado, fechado_em, fechado_por)
  values (empresa, p_mes, coalesce(p_bloqueado, false), case when p_fechado then now() end, case when p_fechado then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set bloqueado = excluded.bloqueado,
        fechado_em = case when p_fechado then coalesce(public.empresa_meses.fechado_em, now()) end,
        fechado_por = case when p_fechado then coalesce(public.empresa_meses.fechado_por, auth.uid()) end;
  perform public.registar_empresa(empresa, 'definicoes', to_char(p_mes, 'MM/YYYY') || ': ' ||
    case when p_fechado then 'informação completa (mês fechado)' when p_bloqueado then 'envio de documentos bloqueado' else 'aberto para envio' end);
end $$;

-- A versão da ligação ao Cegid de uma empresa: entra na chave da cache do
-- portal. Subir a versão é deitar a cache fora.
create function public.renovar_cegid_empresa(empresa uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  update public.companies set cegid_versao = cegid_versao + 1 where id = empresa returning cegid_versao into v;
  if v is null then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  return v;
end $$;

-- A ficha: os dois lados escrevem, e cada campo alterado fica no histórico.
create function public.guardar_ficha_empresa(empresa uuid, dados jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  staff boolean := public.is_staff();
  c public.companies;
  f public.empresa_fichas;
  antes jsonb;
  depois jsonb;
  k text;
  permitidos text[] := array['nome', 'nif', 'forma_juridica', 'cae', 'regime_iva', 'regime_iva_outro', 'tem_trabalhadores',
    'morada', 'codigo_postal', 'localidade', 'capital_social', 'representantes', 'niss', 'iban', 'email', 'telefone',
    'contacto_nome', 'contacto_email', 'contacto_telefone'];
  alterados text[] := '{}';
  v text;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if dados is null or jsonb_typeof(dados) <> 'object' then raise exception 'Dados inválidos' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(dados) loop
    if not k = any(permitidos) then raise exception 'Campo desconhecido: %', k using errcode = '22023'; end if;
  end loop;

  select * into c from public.companies where id = empresa for update;
  insert into public.empresa_fichas(company_id) values (empresa) on conflict do nothing;
  select * into f from public.empresa_fichas where company_id = empresa for update;
  antes := to_jsonb(f) || jsonb_build_object('nome', c.name, 'nif', c.nif);

  -- Normaliza: texto aparado, vazio é nulo; IBAN sem espaços e em maiúsculas.
  depois := antes;
  for k in select jsonb_object_keys(dados) loop
    if k = 'tem_trabalhadores' then
      depois := jsonb_set(depois, array[k], to_jsonb(coalesce((dados->>k)::boolean, false)));
    elsif k = 'capital_social' then
      depois := jsonb_set(depois, array[k], coalesce(to_jsonb(nullif(btrim(dados->>k), '')::numeric(16, 2)), 'null'::jsonb));
    else
      v := nullif(btrim(coalesce(dados->>k, '')), '');
      if k = 'iban' and v is not null then v := upper(replace(v, ' ', '')); end if;
      depois := jsonb_set(depois, array[k], coalesce(to_jsonb(v), 'null'::jsonb));
    end if;
  end loop;

  if depois->>'nome' is null or length(depois->>'nome') > 200 then raise exception 'Indique o nome da empresa' using errcode = '22023'; end if;
  if (depois->>'nif') is distinct from c.nif and not coalesce(public.nif_valido(depois->>'nif'), false) then
    raise exception 'NIF inválido' using errcode = '22023';
  end if;
  if (depois->>'nif') is distinct from c.nif and exists (select 1 from public.companies where nif = depois->>'nif' and id <> empresa) then
    raise exception 'Já existe uma empresa com este NIF' using errcode = '23505';
  end if;

  update public.companies set name = depois->>'nome', nif = depois->>'nif' where id = empresa;
  update public.empresa_fichas set
    forma_juridica = depois->>'forma_juridica', cae = depois->>'cae', regime_iva = depois->>'regime_iva',
    regime_iva_outro = depois->>'regime_iva_outro', tem_trabalhadores = (depois->>'tem_trabalhadores')::boolean,
    morada = depois->>'morada', codigo_postal = depois->>'codigo_postal', localidade = depois->>'localidade',
    capital_social = (depois->>'capital_social')::numeric(16, 2), representantes = depois->>'representantes',
    niss = depois->>'niss', iban = depois->>'iban', email = depois->>'email', telefone = depois->>'telefone',
    contacto_nome = depois->>'contacto_nome', contacto_email = depois->>'contacto_email',
    contacto_telefone = depois->>'contacto_telefone', atualizado_em = now(), atualizado_por = auth.uid()
  where company_id = empresa;

  foreach k in array permitidos loop
    if (antes->>k) is distinct from (depois->>k) then
      alterados := alterados || k;
      insert into public.empresa_ficha_historico(company_id, campo, antes, depois, origem, alterado_por)
      values (empresa, k, antes->>k, depois->>k, case when staff then 'gestao' else 'portal' end, auth.uid());
    end if;
  end loop;
  if array_length(alterados, 1) > 0 then
    perform public.registar_empresa(empresa, 'ficha', 'Dados da empresa alterados: ' || array_to_string(alterados, ', '));
  end if;
  return coalesce(array_length(alterados, 1), 0);
end $$;

create function public.ler_alerta_empresa(alerta uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.empresa_alertas;
begin
  select * into a from public.empresa_alertas where id = alerta;
  if not found or auth.uid() is null then raise exception 'Alerta indisponível' using errcode = '42501'; end if;
  if a.company_id is not null and not public.pode_aceder_empresa(a.company_id) then
    raise exception 'Alerta indisponível' using errcode = '42501';
  end if;
  if a.company_id is null and not public.is_staff() and not exists (
       select 1 from public.company_users cu where cu.user_id = auth.uid() and cu.active and public.pode_aceder_empresa(cu.company_id)) then
    raise exception 'Alerta indisponível' using errcode = '42501';
  end if;
  insert into public.empresa_alertas_lidos(alerta_id, user_id) values (alerta, auth.uid()) on conflict do nothing;
end $$;

create function public.definir_logotipo_empresa(empresa uuid, caminho text) returns text
language plpgsql security definer set search_path = '' as $$
declare anterior text;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if caminho is not null and (public.logotipo_da_empresa(caminho) is distinct from empresa
     or not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-logotipos' and o.name = caminho)) then
    raise exception 'Logótipo inválido' using errcode = '22023';
  end if;
  select logotipo_caminho into anterior from public.companies where id = empresa for update;
  update public.companies set logotipo_caminho = caminho, logotipo_em = case when caminho is null then null else now() end where id = empresa;
  perform public.registar_empresa(empresa, 'logotipo', case when caminho is null then 'Logótipo retirado' else 'Logótipo atualizado' end);
  return anterior;
end $$;

-- Pessoal.
create function public.comunicar_pessoal(empresa uuid, p_tipo text, p_trabalhador text, p_dados jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare novo uuid;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if not coalesce((select tem_trabalhadores from public.empresa_fichas where company_id = empresa), false) then
    raise exception 'Esta empresa não tem trabalhadores registados' using errcode = '22023';
  end if;
  insert into public.empresa_pessoal(company_id, tipo, trabalhador, dados, criado_por)
  values (empresa, p_tipo, btrim(p_trabalhador), coalesce(p_dados, '{}'::jsonb), auth.uid()) returning id into novo;
  perform public.registar_empresa(empresa, 'pessoal',
    case p_tipo when 'admissao' then 'Admissão comunicada: ' when 'cessacao' then 'Cessação comunicada: '
                when 'ausencia' then 'Ausência comunicada: ' else 'Alteração comunicada: ' end || btrim(p_trabalhador));
  return novo;
end $$;

create function public.tratar_pessoal(pedido uuid, p_estado text, p_resposta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.empresa_pessoal;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista trata o pessoal' using errcode = '42501'; end if;
  if p_estado not in ('novo', 'em_tratamento', 'tratado', 'devolvido') then raise exception 'Estado inválido' using errcode = '22023'; end if;
  update public.empresa_pessoal
     set estado = p_estado, resposta = nullif(left(btrim(coalesce(p_resposta, '')), 1000), ''),
         tratado_em = case when p_estado in ('tratado', 'devolvido') then now() end,
         tratado_por = case when p_estado in ('tratado', 'devolvido') then auth.uid() end
   where id = pedido returning * into p;
  if p.id is null then raise exception 'Pedido desconhecido' using errcode = '22023'; end if;
  perform public.registar_empresa(p.company_id, 'pessoal',
    p.trabalhador || ': ' || case p_estado when 'tratado' then 'tratado pelo contabilista' when 'devolvido' then 'devolvido'
                                            when 'em_tratamento' then 'em tratamento' else 'reaberto' end);
end $$;

create function public.preparar_recibos_mes(empresa uuid, p_mes date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista publica recibos' using errcode = '42501'; end if;
  if p_mes is null or p_mes <> date_trunc('month', p_mes)::date then raise exception 'Mês inválido' using errcode = '22023'; end if;
  insert into public.empresa_recibos(company_id, mes) values (empresa, p_mes)
  on conflict (company_id, mes) do update set mes = excluded.mes returning id into r;
  return r;
end $$;

-- Impostos.
create function public.guardar_imposto(p_id uuid, empresa uuid, p_tipo text, p_periodo text, p_descricao text,
  p_referencia text, p_valor numeric, p_prazo date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  if not public.is_staff() then raise exception 'Apenas o contabilista publica impostos' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empresa_impostos(company_id, tipo, periodo, descricao, referencia, valor, prazo, criado_por)
    values (empresa, p_tipo, btrim(p_periodo), nullif(btrim(coalesce(p_descricao, '')), ''), nullif(btrim(coalesce(p_referencia, '')), ''),
            p_valor, p_prazo, auth.uid()) returning id into r;
    perform public.registar_empresa(empresa, 'imposto', p_tipo || ' ' || btrim(p_periodo) || ' publicado'
      || coalesce(' · prazo ' || to_char(p_prazo, 'DD/MM/YYYY'), ''));
  else
    update public.empresa_impostos
       set tipo = p_tipo, periodo = btrim(p_periodo), descricao = nullif(btrim(coalesce(p_descricao, '')), ''),
           referencia = nullif(btrim(coalesce(p_referencia, '')), ''), valor = p_valor, prazo = p_prazo
     where id = p_id and company_id = empresa returning id into r;
    if r is null then raise exception 'Imposto desconhecido' using errcode = '22023'; end if;
  end if;
  return r;
end $$;

create function public.apagar_imposto(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.empresa_impostos;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode = '42501'; end if;
  delete from public.empresa_impostos where id = p_id returning * into i;
  if i.id is null then raise exception 'Imposto desconhecido' using errcode = '22023'; end if;
  delete from public.empresa_ficheiros where ref_id = p_id and contexto in ('guia', 'comprovativo');
  perform public.registar_empresa(i.company_id, 'imposto', i.tipo || ' ' || i.periodo || ' apagado');
end $$;

create function public.marcar_imposto_pago(p_id uuid, pago boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.empresa_impostos;
begin
  select * into i from public.empresa_impostos where id = p_id for update;
  if not found or auth.uid() is null or not public.pode_aceder_empresa(i.company_id) then
    raise exception 'Imposto indisponível' using errcode = '42501';
  end if;
  update public.empresa_impostos
     set estado = case when pago then 'pago' else 'por_pagar' end,
         pago_em = case when pago then coalesce(pago_em, now()) end,
         pago_por = case when pago then coalesce(pago_por, auth.uid()) end
   where id = p_id;
  perform public.registar_empresa(i.company_id, 'imposto',
    i.tipo || ' ' || i.periodo || case when pago then ' marcado como pago' else ' marcado como por pagar' end);
end $$;

-- Ficheiros: o mesmo circuito dos documentos do mês (pendente → Storage →
-- carregado), com quem pode o quê decidido pelo contexto.
create function public.preparar_ficheiro_empresa(empresa uuid, p_contexto text, p_ref uuid, p_nome text, p_mime text, p_tamanho bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  staff boolean := public.is_staff();
  novo uuid := gen_random_uuid();
  caminho text;
begin
  if auth.uid() is null or not public.user_enabled(auth.uid()) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if p_contexto in ('recibos', 'guia') and not staff then
    raise exception 'Apenas o contabilista publica este ficheiro' using errcode = '42501';
  end if;
  if (p_contexto = 'pessoal' and not exists (select 1 from public.empresa_pessoal where id = p_ref and company_id = empresa))
     or (p_contexto = 'recibos' and not exists (select 1 from public.empresa_recibos where id = p_ref and company_id = empresa))
     or (p_contexto in ('guia', 'comprovativo') and not exists (select 1 from public.empresa_impostos where id = p_ref and company_id = empresa))
     or p_contexto not in ('pessoal', 'recibos', 'guia', 'comprovativo') then
    raise exception 'Referência inválida' using errcode = '22023';
  end if;
  caminho := empresa::text || '/' || p_contexto || '/' || p_ref::text || '/' || novo::text || '.' ||
    case p_mime when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' else 'bin' end;
  insert into public.empresa_ficheiros(id, company_id, contexto, ref_id, nome, caminho, mime, tamanho, enviado_por)
  values (novo, empresa, p_contexto, p_ref, left(btrim(p_nome), 220), caminho, p_mime, p_tamanho, auth.uid());
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create function public.concluir_ficheiro_empresa(ficheiro uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or f.enviado_por is distinct from auth.uid() or not public.pode_aceder_empresa(f.company_id) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if f.estado = 'pendente' then
    if not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho) then
      raise exception 'O ficheiro ainda não chegou' using errcode = '22023';
    end if;
    update public.empresa_ficheiros set estado = 'carregado', carregado_em = now() where id = f.id;
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

create function public.apagar_ficheiro_empresa(ficheiro uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro for update;
  if not found or not public.pode_aceder_empresa(f.company_id)
     or (f.enviado_por is distinct from auth.uid() and not public.is_staff()) then
    raise exception 'Ficheiro indisponível' using errcode = '42501';
  end if;
  if exists (select 1 from storage.objects o where o.bucket_id = 'empresas-ficheiros' and o.name = f.caminho) then
    raise exception 'Apague primeiro o ficheiro' using errcode = '22023';
  end if;
  delete from public.empresa_ficheiros where id = f.id;
end $$;

create function public.registar_descarga_empresa(ficheiro uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.empresa_ficheiros;
begin
  select * into f from public.empresa_ficheiros where id = ficheiro;
  if not found or not public.pode_aceder_empresa(f.company_id) then raise exception 'Ficheiro indisponível' using errcode = '42501'; end if;
  if public.is_staff() then return; end if;
  if f.contexto = 'recibos' then
    update public.empresa_recibos set descarregado_em = coalesce(descarregado_em, now()) where id = f.ref_id;
  end if;
  perform public.registar_empresa(f.company_id, 'descarga', 'Descarregou «' || f.nome || '»');
end $$;

-- ------------------------------------------------ regras novas nas antigas

-- Envio de documentos: nada antes do início, nada em meses bloqueados ou
-- fechados (o contabilista pode sempre).
create or replace function public.preparar_documento_empresa(
  empresa uuid, mes date, categoria text, nome text, mime text,
  tamanho bigint, tamanho_original bigint default null, nota text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  eu uuid := auth.uid();
  atual date := public.mes_lisboa();
  novo uuid := gen_random_uuid();
  caminho text;
  inicio_empresa date;
  m public.empresa_meses;
begin
  if eu is null or not public.user_enabled(eu) or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > atual or mes < (atual - interval '24 months')::date then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  select inicio into inicio_empresa from public.companies where id = empresa;
  if inicio_empresa is not null and mes < inicio_empresa then
    raise exception 'Mês anterior ao início do acompanhamento' using errcode = '22023';
  end if;
  select * into m from public.empresa_meses em where em.company_id = empresa and em.mes = preparar_documento_empresa.mes;
  if not public.is_staff() and (m.bloqueado or m.fechado_em is not null) then
    raise exception 'Mês fechado para envio' using errcode = '22023';
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

create or replace function public.marcar_mes_completo(empresa uuid, mes date, completo boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  if mes is null or mes <> date_trunc('month', mes)::date or mes > public.mes_lisboa() then
    raise exception 'Mês inválido' using errcode = '22023';
  end if;
  if not public.is_staff() and exists (select 1 from public.empresa_meses em
       where em.company_id = empresa and em.mes = marcar_mes_completo.mes and em.fechado_em is not null) then
    raise exception 'Mês fechado pelo contabilista' using errcode = '22023';
  end if;
  insert into public.empresa_meses(company_id, mes, completo_em, completo_por)
  values (empresa, mes, case when completo then now() end, case when completo then auth.uid() end)
  on conflict on constraint empresa_meses_pkey do update
    set completo_em = excluded.completo_em, completo_por = excluded.completo_por;
  perform public.registar_empresa(empresa, 'mes_completo',
    to_char(mes, 'MM/YYYY') || case when completo then ': documentação dada como completa' else ': reaberto para mais documentos' end);
end $$;

-- A data de corte sobe a versão do Cegid em vez de apagar a cache.
create or replace function public.definir_data_corte(empresa uuid, corte date, nota text default null) returns void
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
     set data_corte = corte, data_corte_em = now(), data_corte_por = auth.uid(), cegid_versao = cegid_versao + 1
   where id = empresa;
  if not found then raise exception 'Empresa desconhecida' using errcode = '22023'; end if;
  insert into public.empresa_cortes(company_id, data_corte, nota, definido_por)
  values (empresa, corte, nullif(left(btrim(coalesce(nota, '')), 500), ''), auth.uid());
  perform public.registar_empresa(empresa, 'data_corte',
    case when corte is null then 'Data de corte retirada'
         else 'Data de corte: ' || to_char(corte, 'DD/MM/YYYY') end);
end $$;

drop table public.empresa_cegid_cache;

-- O contexto do portal: mais o logótipo, a versão do Cegid e o pessoal.
create or replace function public.portal_empresas() returns jsonb
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
               'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'inicio', c.inicio,
               'logotipo', c.logotipo_caminho, 'logotipo_em', c.logotipo_em, 'cegid_versao', c.cegid_versao,
               'tem_trabalhadores', coalesce((select f.tem_trabalhadores from public.empresa_fichas f where f.company_id = c.id), false),
               'tem_cegid', exists (select 1 from public.integration_secrets s where s.scope = 'cegid:' || c.id::text))
             order by c.name)
        from public.companies c
       where c.active and public.pode_aceder_empresa(c.id)), '[]'::jsonb));
end $$;

-- A visão geral: meses só a partir do início, com bloqueio e fecho, e o que
-- há para pagar.
create or replace function public.empresa_resumo(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.companies;
  staff boolean := public.is_staff();
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  atual date := public.mes_lisboa();
  em_curso date;
begin
  if auth.uid() is null or not public.pode_aceder_empresa(empresa) then
    raise exception 'Sem acesso a esta empresa' using errcode = '42501';
  end if;
  select * into c from public.companies where id = empresa;
  em_curso := case when extract(day from hoje) <= 10 then (atual - interval '1 month')::date else atual end;
  if c.inicio is not null and em_curso < c.inicio then em_curso := c.inicio; end if;
  return jsonb_build_object(
    'empresa', jsonb_build_object(
      'id', c.id, 'nome', c.name, 'nif', c.nif, 'data_corte', c.data_corte, 'data_corte_em', c.data_corte_em, 'inicio', c.inicio,
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
               'conferido_em', em.conferido_em,
               'bloqueado', coalesce(em.bloqueado, false),
               'fechado_em', em.fechado_em) order by m.mes desc), '[]'::jsonb)
        from (select (atual - make_interval(months => g))::date as mes from generate_series(0, 5) g) m
        left join public.empresa_meses em on em.company_id = empresa and em.mes = m.mes
       where c.inicio is null or m.mes >= c.inicio),
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
    'impostos', (
      select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'tipo', i.tipo, 'periodo', i.periodo, 'valor', i.valor,
                                                   'prazo', i.prazo, 'atrasado', i.prazo < hoje) order by i.prazo nulls last), '[]'::jsonb)
        from (select * from public.empresa_impostos i where i.company_id = empresa and i.estado = 'por_pagar'
               order by i.prazo nulls last limit 6) i),
    'atividade', (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'detalhe', a.detalhe, 'em', a.criado_em)
                                order by a.criado_em desc), '[]'::jsonb)
        from (select * from public.empresa_atividade a where a.company_id = empresa
               order by a.criado_em desc limit 8) a));
end $$;

create or replace function public.gestao_empresas() returns jsonb
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
        'mensagens', (select count(*) from public.empresa_mensagens m where m.company_id = c.id and m.lida_em is null and not m.do_gabinete),
        'pessoal', (select count(*) from public.empresa_pessoal p where p.company_id = c.id and p.estado = 'novo'),
        'impostos_atrasados', (select count(*) from public.empresa_impostos i where i.company_id = c.id and i.estado = 'por_pagar' and i.prazo < hoje)))
        from public.companies c), '[]'::jsonb));
end $$;

-- ------------------------------------------------------- execute das funções
do $x$
declare f text;
begin
  foreach f in array array[
    'public.nif_valido(text)', 'public.logotipo_da_empresa(text)',
    'public.definir_inicio_empresa(uuid,date)', 'public.definir_mes_empresa(uuid,date,boolean,boolean)',
    'public.renovar_cegid_empresa(uuid)', 'public.guardar_ficha_empresa(uuid,jsonb)', 'public.ler_alerta_empresa(uuid)',
    'public.definir_logotipo_empresa(uuid,text)', 'public.comunicar_pessoal(uuid,text,text,jsonb)',
    'public.tratar_pessoal(uuid,text,text)', 'public.preparar_recibos_mes(uuid,date)',
    'public.guardar_imposto(uuid,uuid,text,text,text,text,numeric,date)', 'public.apagar_imposto(uuid)',
    'public.marcar_imposto_pago(uuid,boolean)',
    'public.preparar_ficheiro_empresa(uuid,text,uuid,text,text,bigint)', 'public.concluir_ficheiro_empresa(uuid)',
    'public.apagar_ficheiro_empresa(uuid)', 'public.registar_descarga_empresa(uuid)',
    'public.preparar_documento_empresa(uuid,date,text,text,text,bigint,bigint,text)',
    'public.marcar_mes_completo(uuid,date,boolean)', 'public.definir_data_corte(uuid,date,text)',
    'public.portal_empresas()', 'public.empresa_resumo(uuid)', 'public.gestao_empresas()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $x$;

commit;
