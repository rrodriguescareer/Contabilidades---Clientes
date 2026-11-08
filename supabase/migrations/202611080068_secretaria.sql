-- A Secretária: pedir, acompanhar e receber os documentos em falta dos clientes.
--
-- Pendência: um documento que falta. Processo: o pedido e as insistências de
-- um cliente (um de cada vez). Envio: cada email, com o estado da aprovação.
-- O cliente não precisa de conta: cada email leva uma ligação própria, de que
-- só se guarda o hash. Tudo o que muda fica numa cadeia de auditoria.
begin;

alter table public.empresa_documentos alter column enviado_por drop not null;

create table public.secretaria_definicoes (
  id boolean primary key default true check (id),
  aprovar text not null default 'primeiro' check (aprovar in ('primeiro', 'todos', 'nenhum')),
  cadencia jsonb not null default '{"modo":"corridos","intervalo":7,"hora":9}'::jsonb,
  dia_limite smallint not null default 10 check (dia_limite between 1 and 28),
  resumo_semanal boolean not null default true,
  atualizado_em timestamptz not null default now()
);
insert into public.secretaria_definicoes default values;

create table public.secretaria_clientes (
  company_id uuid primary key references public.companies(id) on delete cascade,
  periodicidade text not null default 'mensal' check (periodicidade in ('mensal', 'trimestral', 'isento')),
  envio_automatico boolean not null default true,
  dia_limite smallint check (dia_limite between 1 and 28),
  cadencia jsonb,
  responsavel text check (responsavel is null or length(responsavel) <= 120),
  atualizado_em timestamptz not null default now()
);

create table public.secretaria_contactos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  nome text not null check (length(btrim(nome)) between 1 and 120),
  email text not null check (length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  principal boolean not null default false,
  em_cc boolean not null default false,
  contactavel boolean not null default true,
  criado_em timestamptz not null default now()
);
create unique index secretaria_contactos_email on public.secretaria_contactos(company_id, lower(email));
create unique index secretaria_contactos_principal on public.secretaria_contactos(company_id) where principal;

create table public.secretaria_pendencias (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  periodo date not null check (periodo = (date_trunc('month', periodo::timestamp))::date),
  tipo text not null default 'FT' check (tipo in ('FT', 'FS', 'FR', 'ND', 'NC', 'RC', 'MB', 'EB', 'OUTRO')),
  descricao text not null check (length(btrim(descricao)) between 1 and 200),
  numero text check (numero is null or length(numero) <= 80),
  data_documento date,
  valor_cents bigint,
  banco text check (banco is null or length(banco) <= 80),
  origem text not null default 'manual' check (origem in ('manual', 'importacao', 'recorrente')),
  estado text not null default 'pendente' check (estado in ('pendente', 'recebida', 'associada', 'anulada')),
  acompanhar boolean not null default true,
  documento_id uuid references public.empresa_documentos(id) on delete set null,
  criado_em timestamptz not null default now(),
  criado_por uuid,
  recebida_em timestamptz,
  associada_em timestamptz
);
create index secretaria_pendencias_periodo on public.secretaria_pendencias(company_id, periodo);
create index secretaria_pendencias_abertas on public.secretaria_pendencias(company_id) where estado = 'pendente';
create index secretaria_pendencias_documento on public.secretaria_pendencias(documento_id);
create unique index secretaria_pendencias_unica on public.secretaria_pendencias(company_id, tipo, numero, data_documento)
  where numero is not null and data_documento is not null and estado <> 'anulada';

alter table public.empresa_documentos
  add column pendencia_id uuid references public.secretaria_pendencias(id) on delete set null;
create index empresa_documentos_pendencia on public.empresa_documentos(pendencia_id);

create table public.secretaria_recorrentes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null default 'EB' check (tipo in ('FT', 'FS', 'FR', 'ND', 'NC', 'RC', 'MB', 'EB', 'OUTRO')),
  descricao text not null check (length(btrim(descricao)) between 1 and 200),
  banco text check (banco is null or length(banco) <= 80),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create unique index secretaria_recorrentes_unica on public.secretaria_recorrentes(company_id, tipo, lower(descricao));

create table public.secretaria_processos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  estado text not null default 'em_curso' check (estado in ('em_curso', 'terminado')),
  motivo text check (motivo in ('nada_falta', 'dia_limite', 'cancelado', 'sem_documentos', 'sem_contacto')),
  dia_limite date not null,
  proximo_envio timestamptz,
  iniciado_em timestamptz not null default now(),
  iniciado_por uuid,
  terminado_em timestamptz,
  primeiro_contacto timestamptz,
  ultimo_contacto timestamptz,
  ultima_resposta timestamptz,
  insistencias integer not null default 0
);
create unique index secretaria_processos_um_em_curso on public.secretaria_processos(company_id) where estado = 'em_curso';
create index secretaria_processos_empresa on public.secretaria_processos(company_id, iniciado_em desc);
create index secretaria_processos_proximo on public.secretaria_processos(proximo_envio) where estado = 'em_curso';

create table public.secretaria_envios (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.secretaria_processos(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('pedido', 'insistencia')),
  estado text not null check (estado in ('por_aprovar', 'rejeitado', 'a_enviar', 'enviado', 'falhou')),
  assunto text not null check (length(assunto) between 1 and 250),
  corpo text not null check (length(corpo) between 1 and 8000),
  para text,
  cc text[] not null default '{}',
  pendencias integer not null default 0,
  criado_em timestamptz not null default now(),
  decidido_em timestamptz,
  decidido_por uuid,
  reservado_em timestamptz,
  tentativas integer not null default 0,
  enviado_em timestamptz,
  erro text,
  token_hash text unique
);
create index secretaria_envios_processo on public.secretaria_envios(processo_id, criado_em desc);
create index secretaria_envios_empresa on public.secretaria_envios(company_id, criado_em desc);
create index secretaria_envios_estado on public.secretaria_envios(estado) where estado in ('por_aprovar', 'a_enviar', 'falhou');

create table public.secretaria_modelos (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  tipo text not null check (tipo in ('pedido', 'insistencia')),
  assunto text not null check (length(btrim(assunto)) between 1 and 250),
  corpo text not null check (length(btrim(corpo)) between 1 and 8000),
  atualizado_em timestamptz not null default now()
);
create unique index secretaria_modelos_unico on public.secretaria_modelos(coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid), tipo);

insert into public.secretaria_modelos (tipo, assunto, corpo) values
('pedido', 'Documentos em falta — {{cliente}} ({{periodo}})',
$m$Exmos. Senhores,

Para podermos concluir a contabilidade de {{periodo}} de {{cliente}}, solicitamos o envio dos seguintes documentos ({{numero}}), organizados por categoria:

{{lista}}

Pedimos a entrega até {{prazo}}, pela ligação abaixo, onde pode juntar cada documento ao respetivo pedido.

Com os melhores cumprimentos,
{{remetente}}$m$),
('insistencia', 'Lembrete: documentos em falta — {{cliente}}',
$m$Exmos. Senhores,

Lembramos que continuam por receber os seguintes documentos ({{numero}}) de {{cliente}}, referentes a {{periodo}}:

{{lista}}

A data limite para a entrega é {{prazo}}. Caso já tenha enviado estes documentos, agradecemos que desconsidere este lembrete.

Com os melhores cumprimentos,
{{remetente}}$m$);

create table public.secretaria_por_identificar (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  documento_id uuid not null unique references public.empresa_documentos(id) on delete cascade,
  estado text not null default 'por_rever' check (estado in ('por_rever', 'arquivado', 'revisto')),
  pendencia_id uuid references public.secretaria_pendencias(id) on delete set null,
  criado_em timestamptz not null default now(),
  revisto_em timestamptz,
  revisto_por uuid
);
create index secretaria_por_identificar_estado on public.secretaria_por_identificar(estado, criado_em desc);
create index secretaria_por_identificar_empresa on public.secretaria_por_identificar(company_id);
create index secretaria_por_identificar_pendencia on public.secretaria_por_identificar(pendencia_id);

create table public.secretaria_respostas (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.secretaria_processos(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  texto text not null check (length(btrim(texto)) between 1 and 2000),
  criado_em timestamptz not null default now()
);
create index secretaria_respostas_empresa on public.secretaria_respostas(company_id, criado_em desc);
create index secretaria_respostas_processo on public.secretaria_respostas(processo_id);

-- Só se acrescenta. Cada linha leva o hash da anterior: alterar o passado
-- parte a cadeia e a verificação diz onde.
create table public.secretaria_auditoria (
  seq bigint generated always as identity primary key,
  quando timestamptz not null default now(),
  acao text not null,
  autor text not null,
  company_id uuid,
  empresa text,
  detalhe text,
  hash text not null
);
create index secretaria_auditoria_empresa on public.secretaria_auditoria(company_id, seq desc);

create table public.secretaria_chave (
  id boolean primary key default true check (id),
  hash text not null
);

do $x$
declare t text;
begin
  foreach t in array array['secretaria_definicoes', 'secretaria_clientes', 'secretaria_contactos', 'secretaria_pendencias',
    'secretaria_recorrentes', 'secretaria_processos', 'secretaria_envios', 'secretaria_modelos', 'secretaria_por_identificar',
    'secretaria_respostas', 'secretaria_auditoria', 'secretaria_chave'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    if t = 'secretaria_chave' then continue; end if;
    if t = 'secretaria_auditoria' then
      execute format('grant select on public.%I to authenticated', t);
      execute format('create policy staff on public.%I for select to authenticated using ((select public.is_staff()))', t);
    else
      execute format('grant select, insert, update, delete on public.%I to authenticated', t);
      execute format('create policy staff on public.%I for all to authenticated using ((select public.is_staff())) with check ((select public.is_staff()))', t);
    end if;
    execute format('create policy dois_fatores on public.%I as restrictive for all to authenticated using ((select public.aal_suficiente())) with check ((select public.aal_suficiente()))', t);
  end loop;
end $x$;

create function public.secretaria_bloquear_alteracao() returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'A auditoria não pode ser alterada' using errcode = '42501';
end $$;
create trigger secretaria_auditoria_so_acrescenta before update or delete on public.secretaria_auditoria
  for each row execute function public.secretaria_bloquear_alteracao();

create function public.secretaria_hash(anterior text, quando timestamptz, acao text, autor text, empresa uuid, detalhe text)
returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(concat_ws('|', coalesce(anterior, ''), to_char(quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
    acao, autor, coalesce(empresa::text, ''), coalesce(detalhe, '')), 'UTF8')), 'hex')
$$;

create function public.secretaria_registar(p_acao text, p_empresa uuid, p_detalhe text, p_autor text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  anterior text;
  agora timestamptz := clock_timestamp();
  quem text;
begin
  perform pg_advisory_xact_lock(7240311);
  select a.hash into anterior from public.secretaria_auditoria a order by a.seq desc limit 1;
  quem := coalesce(p_autor, (select u.email from auth.users u where u.id = auth.uid()), 'Sistema');
  insert into public.secretaria_auditoria (quando, acao, autor, company_id, empresa, detalhe, hash)
  values (agora, p_acao, quem, p_empresa, (select c.name from public.companies c where c.id = p_empresa), left(p_detalhe, 1000),
          public.secretaria_hash(anterior, agora, p_acao, quem, p_empresa, left(p_detalhe, 1000)));
end $$;

create function public.secretaria_auditar(p_acao text, p_empresa uuid, p_detalhe text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  perform public.secretaria_registar(p_acao, p_empresa, p_detalhe);
end $$;

create function public.secretaria_auditoria_verificar() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a record; anterior text; n bigint := 0;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  for a in select * from public.secretaria_auditoria order by seq loop
    if a.hash is distinct from public.secretaria_hash(anterior, a.quando, a.acao, a.autor, a.company_id, a.detalhe) then
      return jsonb_build_object('valida', false, 'eventos', n, 'quebra', a.seq);
    end if;
    anterior := a.hash;
    n := n + 1;
  end loop;
  return jsonb_build_object('valida', true, 'eventos', n);
end $$;

create function public.secretaria_proximo_envio(cad jsonb, depois timestamptz)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare
  agora_local timestamp := depois at time zone 'Europe/Lisbon';
  dia date := agora_local::date;
  hora int := coalesce((cad->>'hora')::int, 9);
  n int := greatest(coalesce((cad->>'intervalo')::int, 7), 1);
  candidato timestamp;
  h int;
  i int := 0;
begin
  if coalesce(cad->>'modo', 'corridos') = 'semana' then
    for i in 0..7 loop
      h := (cad->'dias'->>(extract(isodow from dia + i)::int)::text)::int;
      if h is not null then
        candidato := (dia + i)::timestamp + make_interval(hours => h);
        if candidato > agora_local then return candidato at time zone 'Europe/Lisbon'; end if;
      end if;
    end loop;
    return ((dia + 7)::timestamp + make_interval(hours => hora)) at time zone 'Europe/Lisbon';
  elsif cad->>'modo' = 'uteis' then
    while i < n loop
      dia := dia + 1;
      if extract(isodow from dia) < 6 then i := i + 1; end if;
    end loop;
    return (dia::timestamp + make_interval(hours => hora)) at time zone 'Europe/Lisbon';
  end if;
  return ((dia + n)::timestamp + make_interval(hours => hora)) at time zone 'Europe/Lisbon';
end $$;

create function public.secretaria_cadencia_de(empresa uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.cadencia from public.secretaria_clientes c where c.company_id = empresa),
                  (select d.cadencia from public.secretaria_definicoes d limit 1))
$$;

create function public.secretaria_automatico(empresa uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.envio_automatico from public.secretaria_clientes c where c.company_id = empresa), true)
$$;

create function public.secretaria_tem_contacto(empresa uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.secretaria_contactos c where c.company_id = empresa and c.principal and c.contactavel)
$$;

create function public.secretaria_novo_envio(p_processo uuid, p_tipo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  p public.secretaria_processos;
  politica text;
  m public.secretaria_modelos;
  novo uuid;
begin
  select * into p from public.secretaria_processos where id = p_processo;
  select d.aprovar into politica from public.secretaria_definicoes d limit 1;
  select * into m from public.secretaria_modelos x
   where x.tipo = p_tipo and (x.company_id = p.company_id or x.company_id is null)
   order by x.company_id nulls last limit 1;
  insert into public.secretaria_envios (processo_id, company_id, tipo, estado, assunto, corpo, pendencias)
  values (p.id, p.company_id, p_tipo,
          case when politica = 'todos' or (politica = 'primeiro' and p_tipo = 'pedido') then 'por_aprovar' else 'a_enviar' end,
          coalesce(m.assunto, 'Documentos em falta — {{cliente}}'), coalesce(m.corpo, E'Exmos. Senhores,\n\n{{lista}}\n\n{{remetente}}'),
          (select count(*) from public.secretaria_pendencias q where q.company_id = p.company_id and q.estado = 'pendente' and q.acompanhar))
  returning id into novo;
  return novo;
end $$;

create function public.secretaria_terminar(p_processo uuid, p_motivo text, p_autor text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.secretaria_processos;
begin
  update public.secretaria_processos
     set estado = 'terminado', motivo = p_motivo, terminado_em = now(), proximo_envio = null
   where id = p_processo and estado = 'em_curso' returning * into p;
  if not found then return; end if;
  update public.secretaria_envios set estado = 'rejeitado', decidido_em = now(), erro = 'O processo terminou antes do envio.'
   where processo_id = p.id and estado in ('por_aprovar', 'a_enviar', 'falhou');
  perform public.secretaria_registar('Processo terminado', p.company_id, case p_motivo
    when 'nada_falta' then 'Não falta nada.' when 'dia_limite' then 'Chegou ao dia limite.' when 'cancelado' then 'Cancelado.'
    when 'sem_documentos' then 'Sem documentos em acompanhamento.' else 'Sem contacto disponível.' end, p_autor);
end $$;

create function public.secretaria_fechar_se_completo(empresa uuid, p_autor text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare p public.secretaria_processos;
begin
  select * into p from public.secretaria_processos where company_id = empresa and estado = 'em_curso' for update;
  if not found then return false; end if;
  if exists (select 1 from public.secretaria_pendencias q where q.company_id = empresa and q.estado = 'pendente' and q.acompanhar) then return false; end if;
  perform public.secretaria_terminar(p.id,
    case when exists (select 1 from public.secretaria_pendencias q where q.company_id = empresa and q.estado in ('recebida', 'associada') and q.recebida_em >= p.iniciado_em)
         then 'nada_falta' else 'sem_documentos' end, p_autor);
  return true;
end $$;

create function public.secretaria_gerar_recorrentes(p_periodo date) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  mes date := (date_trunc('month', p_periodo::timestamp))::date;
  n integer;
begin
  if auth.uid() is not null and not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  insert into public.secretaria_pendencias (company_id, periodo, tipo, descricao, banco, origem)
  select r.company_id, mes, r.tipo, r.descricao, r.banco, 'recorrente'
    from public.secretaria_recorrentes r
    join public.companies c on c.id = r.company_id and c.active
    left join public.secretaria_clientes s on s.company_id = r.company_id
   where r.ativo
     and coalesce(s.periodicidade, 'mensal') <> 'isento'
     and (coalesce(s.periodicidade, 'mensal') = 'mensal' or extract(month from mes)::int % 3 = 0)
     and not exists (select 1 from public.secretaria_pendencias q
                      where q.company_id = r.company_id and q.periodo = mes and q.origem = 'recorrente'
                        and q.tipo = r.tipo and lower(q.descricao) = lower(r.descricao));
  get diagnostics n = row_count;
  return n;
end $$;

create function public.secretaria_iniciar_processo(empresa uuid, limite date, enviar_ja boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  id_processo uuid;
  envio uuid;
  prox timestamptz;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  if limite is null or limite < hoje then raise exception 'O dia limite tem de ser hoje ou depois' using errcode = '22023'; end if;
  if exists (select 1 from public.secretaria_processos p where p.company_id = empresa and p.estado = 'em_curso') then
    raise exception 'Já há um processo em curso' using errcode = '23505';
  end if;
  if not exists (select 1 from public.secretaria_pendencias q where q.company_id = empresa and q.estado = 'pendente' and q.acompanhar) then
    raise exception 'Não há pendências em acompanhamento' using errcode = '22023';
  end if;
  if not public.secretaria_tem_contacto(empresa) then
    raise exception 'Falta um contacto principal contactável' using errcode = '22023';
  end if;
  if not enviar_ja then
    prox := public.secretaria_proximo_envio(public.secretaria_cadencia_de(empresa), now());
    if (prox at time zone 'Europe/Lisbon')::date > limite then
      raise exception 'O próximo envio seria depois do dia limite' using errcode = '22023';
    end if;
  end if;
  insert into public.secretaria_processos (company_id, dia_limite, proximo_envio, iniciado_por)
  values (empresa, limite, prox, auth.uid()) returning id into id_processo;
  if enviar_ja then envio := public.secretaria_novo_envio(id_processo, 'pedido'); end if;
  perform public.secretaria_registar('Processo iniciado', empresa, 'Dia limite ' || to_char(limite, 'DD/MM/YYYY') ||
    case when enviar_ja then '. Pedido preparado de imediato.' else '. Pedido no próximo envio.' end);
  return jsonb_build_object('id', id_processo, 'envio', envio,
    'estado', (select e.estado from public.secretaria_envios e where e.id = envio));
end $$;

create function public.secretaria_cancelar_processo(p_processo uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  perform public.secretaria_terminar(p_processo, 'cancelado');
end $$;

create function public.secretaria_decidir_envio(envio uuid, aprovar boolean, p_assunto text default null, p_corpo text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.secretaria_envios;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  update public.secretaria_envios
     set estado = case when aprovar then 'a_enviar' else 'rejeitado' end,
         assunto = coalesce(nullif(btrim(p_assunto), ''), assunto), corpo = coalesce(nullif(btrim(p_corpo), ''), corpo),
         decidido_em = now(), decidido_por = auth.uid(), reservado_em = null
   where id = envio and estado = 'por_aprovar' returning * into e;
  if not found then raise exception 'Este pedido já foi decidido' using errcode = '22023'; end if;
  perform public.secretaria_registar(case when aprovar then 'Email aprovado' else 'Email rejeitado' end, e.company_id,
    case e.tipo when 'pedido' then 'Primeiro pedido' else 'Insistência' end);
  if not aprovar and e.tipo = 'pedido' then perform public.secretaria_terminar(e.processo_id, 'cancelado'); end if;
  return jsonb_build_object('id', e.id, 'estado', e.estado);
end $$;

create function public.secretaria_repetir_envio(envio uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  update public.secretaria_envios set estado = 'a_enviar', reservado_em = null, erro = null where id = envio and estado = 'falhou';
  if not found then raise exception 'Este envio não pode ser repetido' using errcode = '22023'; end if;
end $$;

-- O trabalho de cada hora: fecha o que acabou, prepara as insistências e
-- devolve o que há para enviar. Só o servidor a chama.
create function public.secretaria_tarefas() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'Europe/Lisbon')::date;
  r record;
  prox timestamptz;
  criados integer := 0;
  terminados integer := 0;
  lista uuid[];
begin
  if extract(day from hoje) = 1 then
    perform public.secretaria_gerar_recorrentes(((date_trunc('month', hoje::timestamp) - interval '1 month'))::date);
  end if;

  for r in select * from public.secretaria_processos where estado = 'em_curso' for update skip locked loop
    if public.secretaria_fechar_se_completo(r.company_id, 'Sistema') then
      terminados := terminados + 1;
    elsif hoje > r.dia_limite then
      perform public.secretaria_terminar(r.id, 'dia_limite', 'Sistema');
      terminados := terminados + 1;
    elsif not public.secretaria_tem_contacto(r.company_id) then
      perform public.secretaria_terminar(r.id, 'sem_contacto', 'Sistema');
      terminados := terminados + 1;
    end if;
  end loop;

  for r in select * from public.secretaria_processos
            where estado = 'em_curso' and proximo_envio <= now() and public.secretaria_automatico(company_id)
            for update skip locked loop
    if not exists (select 1 from public.secretaria_envios e where e.processo_id = r.id and e.estado in ('por_aprovar', 'a_enviar')) then
      perform public.secretaria_novo_envio(r.id,
        case when exists (select 1 from public.secretaria_envios e where e.processo_id = r.id and e.tipo = 'pedido' and e.estado <> 'rejeitado')
             then 'insistencia' else 'pedido' end);
      criados := criados + 1;
    end if;
    prox := public.secretaria_proximo_envio(public.secretaria_cadencia_de(r.company_id), now());
    update public.secretaria_processos
       set proximo_envio = case when (prox at time zone 'Europe/Lisbon')::date > r.dia_limite then null else prox end
     where id = r.id;
  end loop;

  select coalesce(array_agg(e.id), '{}') into lista from public.secretaria_envios e
   where e.estado = 'a_enviar' and (e.reservado_em is null or e.reservado_em < now() - interval '15 minutes');
  return jsonb_build_object('a_enviar', to_jsonb(lista), 'criados', criados, 'terminados', terminados);
end $$;

create function public.secretaria_pendencias_abertas(empresa uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'periodo', q.periodo, 'tipo', q.tipo, 'descricao', q.descricao,
    'numero', q.numero, 'data_documento', q.data_documento, 'valor_cents', q.valor_cents, 'banco', q.banco)
    order by q.tipo in ('EB', 'MB'), q.tipo = 'OUTRO', q.data_documento nulls last, q.descricao), '[]'::jsonb)
  from public.secretaria_pendencias q where q.company_id = empresa and q.estado = 'pendente' and q.acompanhar
$$;

create function public.secretaria_reservar_envio(envio uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.secretaria_envios; p public.secretaria_processos; c public.companies;
begin
  update public.secretaria_envios
     set reservado_em = now(), tentativas = tentativas + 1
   where id = envio and estado = 'a_enviar' and (reservado_em is null or reservado_em < now() - interval '15 minutes')
   returning * into e;
  if not found then return null; end if;
  select * into p from public.secretaria_processos where id = e.processo_id;
  select * into c from public.companies where id = e.company_id;
  return jsonb_build_object('id', e.id, 'tipo', e.tipo, 'assunto', e.assunto, 'corpo', e.corpo, 'tentativas', e.tentativas,
    'empresa_id', c.id, 'empresa', c.name, 'nif', c.nif, 'dia_limite', p.dia_limite, 'em_curso', p.estado = 'em_curso',
    'contactos', (select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'email', x.email, 'principal', x.principal, 'em_cc', x.em_cc)), '[]'::jsonb)
                    from public.secretaria_contactos x where x.company_id = e.company_id and x.contactavel),
    'pendencias', public.secretaria_pendencias_abertas(e.company_id));
end $$;

create function public.secretaria_envio_resultado(envio uuid, ok boolean, p_para text, p_cc text[], p_hash text, p_erro text) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.secretaria_envios; p public.secretaria_processos; prox timestamptz;
begin
  update public.secretaria_envios
     set estado = case when ok then 'enviado' else 'falhou' end, enviado_em = case when ok then now() end,
         para = p_para, cc = coalesce(p_cc, '{}'), token_hash = case when ok then p_hash end,
         pendencias = case when ok then (select count(*) from public.secretaria_pendencias q where q.company_id = public.secretaria_envios.company_id and q.estado = 'pendente' and q.acompanhar) else pendencias end,
         erro = case when ok then null else left(p_erro, 500) end
   where id = envio and estado = 'a_enviar' returning * into e;
  if not found then return; end if;
  if ok then
    update public.secretaria_processos
       set ultimo_contacto = now(), primeiro_contacto = coalesce(primeiro_contacto, now()),
           insistencias = insistencias + (e.tipo = 'insistencia')::int
     where id = e.processo_id returning * into p;
    if p.estado = 'em_curso' and p.proximo_envio is null and public.secretaria_automatico(p.company_id) then
      prox := public.secretaria_proximo_envio(public.secretaria_cadencia_de(p.company_id), now());
      if (prox at time zone 'Europe/Lisbon')::date <= p.dia_limite then
        update public.secretaria_processos set proximo_envio = prox where id = p.id;
      end if;
    end if;
  end if;
  perform public.secretaria_registar(case when ok then 'Email enviado' else 'Email falhou' end, e.company_id,
    (case e.tipo when 'pedido' then 'Pedido' else 'Insistência' end) || ' para ' || coalesce(p_para, 'sem destinatário') ||
    case when ok then '' else ': ' || coalesce(p_erro, 'erro desconhecido') end, 'Sistema');
end $$;

create function public.secretaria_pendencias_acao(ids uuid[], acao text) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer; empresa uuid;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  if acao not in ('recebida', 'associada', 'reabrir', 'anular', 'acompanhar', 'deixar') then raise exception 'Ação inválida' using errcode = '22023'; end if;
  if acao = 'recebida' then
    update public.secretaria_pendencias set estado = 'recebida', recebida_em = coalesce(recebida_em, now()) where id = any(ids) and estado = 'pendente';
  elsif acao = 'associada' then
    update public.secretaria_pendencias set estado = 'associada', recebida_em = coalesce(recebida_em, now()), associada_em = now() where id = any(ids) and estado in ('pendente', 'recebida');
    update public.empresa_documentos d set estado = 'visto', revisto_em = now(), revisto_por = auth.uid()
      from public.secretaria_pendencias q where q.id = any(ids) and q.documento_id = d.id and d.estado = 'recebido';
  elsif acao = 'reabrir' then
    update public.secretaria_pendencias set estado = 'pendente', recebida_em = null, associada_em = null where id = any(ids) and estado <> 'pendente';
  elsif acao = 'anular' then
    update public.secretaria_pendencias set estado = 'anulada' where id = any(ids) and estado <> 'anulada';
  elsif acao = 'acompanhar' then
    update public.secretaria_pendencias set acompanhar = true where id = any(ids);
  else
    update public.secretaria_pendencias set acompanhar = false where id = any(ids);
  end if;
  get diagnostics n = row_count;
  for empresa in select distinct q.company_id from public.secretaria_pendencias q where q.id = any(ids) loop
    perform public.secretaria_registar(case acao when 'recebida' then 'Marcadas como recebidas' when 'associada' then 'Marcadas como associadas'
      when 'reabrir' then 'Reabertas' when 'anular' then 'Anuladas' when 'acompanhar' then 'Em acompanhamento' else 'Sem acompanhamento' end,
      empresa, n || ' pendência(s)');
    perform public.secretaria_fechar_se_completo(empresa);
  end loop;
  return n;
end $$;

create function public.secretaria_arquivar_documento(p_registo uuid, p_pendencia uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.secretaria_por_identificar; q public.secretaria_pendencias;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  select * into r from public.secretaria_por_identificar where id = p_registo and estado = 'por_rever' for update;
  if not found then raise exception 'Este documento já foi tratado' using errcode = '22023'; end if;
  if p_pendencia is null then
    update public.secretaria_por_identificar set estado = 'arquivado', revisto_em = now(), revisto_por = auth.uid() where id = r.id;
    perform public.secretaria_registar('Documento arquivado', r.company_id, 'Sem pendência: não foi usado.');
    return;
  end if;
  select * into q from public.secretaria_pendencias where id = p_pendencia and company_id = r.company_id for update;
  if not found then raise exception 'Pendência indisponível' using errcode = '22023'; end if;
  update public.secretaria_pendencias set estado = 'recebida', recebida_em = coalesce(recebida_em, now()), documento_id = r.documento_id where id = q.id;
  update public.empresa_documentos set pendencia_id = q.id, mes = q.periodo where id = r.documento_id;
  update public.secretaria_por_identificar set estado = 'arquivado', pendencia_id = q.id, revisto_em = now(), revisto_por = auth.uid() where id = r.id;
  perform public.secretaria_registar('Documento arquivado', r.company_id, 'Associado a «' || q.descricao || '».');
  perform public.secretaria_fechar_se_completo(r.company_id);
end $$;

create function public.secretaria_marcar_revisto(p_registo uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.secretaria_por_identificar;
begin
  if not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  update public.secretaria_por_identificar set estado = 'revisto', revisto_em = now(), revisto_por = auth.uid()
   where id = p_registo and estado = 'por_rever' returning * into r;
  if not found then raise exception 'Este documento já foi tratado' using errcode = '22023'; end if;
  perform public.secretaria_registar('Documento revisto', r.company_id, 'Fica disponível nos documentos da empresa.');
end $$;

create function public.secretaria_painel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare hoje date := (now() at time zone 'Europe/Lisbon')::date;
begin
  if auth.uid() is not null and not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  return jsonb_build_object(
    'recebidos', (select count(*) from public.secretaria_pendencias q where q.recebida_em > now() - interval '30 days'),
    'recebidos_antes', (select count(*) from public.secretaria_pendencias q where q.recebida_em > now() - interval '60 days' and q.recebida_em <= now() - interval '30 days'),
    'em_falta', (select count(*) from public.secretaria_pendencias q join public.companies c on c.id = q.company_id and c.active where q.estado = 'pendente'),
    'por_aprovar', (select count(*) from public.secretaria_envios e where e.estado = 'por_aprovar'),
    'falharam', (select count(*) from public.secretaria_envios e where e.estado = 'falhou'),
    'por_identificar', (select count(*) from public.secretaria_por_identificar p where p.estado = 'por_rever'),
    'processos', (select count(*) from public.secretaria_processos p where p.estado = 'em_curso'),
    'lembretes_hoje', (select count(*) from public.secretaria_envios e where e.estado = 'enviado' and (e.enviado_em at time zone 'Europe/Lisbon')::date = hoje),
    'saem_hoje', (select count(*) from public.secretaria_processos p where p.estado = 'em_curso' and (p.proximo_envio at time zone 'Europe/Lisbon')::date = hoje and p.proximo_envio > now()),
    'sem_processo', (select count(distinct q.company_id) from public.secretaria_pendencias q join public.companies c on c.id = q.company_id and c.active
                      where q.estado = 'pendente' and q.acompanhar
                        and not exists (select 1 from public.secretaria_processos p where p.company_id = q.company_id and p.estado = 'em_curso')),
    'sem_contacto', (select count(distinct q.company_id) from public.secretaria_pendencias q join public.companies c on c.id = q.company_id and c.active
                      where q.estado = 'pendente' and not public.secretaria_tem_contacto(q.company_id)),
    'atividade', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
       select a.seq, a.quando, a.acao, a.autor, a.empresa, a.detalhe, a.company_id from public.secretaria_auditoria a order by a.seq desc limit 6) x));
end $$;

create function public.secretaria_clientes_resumo(desde date, ate date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare hoje date := (now() at time zone 'Europe/Lisbon')::date;
begin
  if auth.uid() is not null and not public.is_staff() then raise exception 'Sem acesso' using errcode = '42501'; end if;
  return (
    select coalesce(jsonb_agg(x.j order by x.j->>'nome'), '[]'::jsonb) from (
      select jsonb_build_object(
        'id', c.id, 'nome', c.name, 'nif', c.nif,
        'periodicidade', coalesce(s.periodicidade, 'mensal'), 'automatico', coalesce(s.envio_automatico, true), 'responsavel', s.responsavel,
        'total', q.total, 'recebidas', q.recebidas, 'em_falta', q.em_falta,
        'em_falta_total', abertas.n,
        'por_aprovar', ap.n, 'tem_contacto', public.secretaria_tem_contacto(c.id),
        'processo', case when pc.id is null then null else jsonb_build_object('id', pc.id, 'dia_limite', pc.dia_limite, 'proximo_envio', pc.proximo_envio,
                     'iniciado_em', pc.iniciado_em, 'insistencias', pc.insistencias) end,
        'ultimo_motivo', ult.motivo, 'ultimo_contacto', coalesce(pc.ultimo_contacto, ult.ultimo_contacto),
        'limite', lim.d,
        'prazo', case
          when q.em_falta = 0 then case when q.total > 0 then 'em_dia' end
          when hoje > lim.d then 'fora'
          when lim.d - hoje >= 14 and q.ritmo = 0 then 'em_dia'
          when lim.d - hoje >= 7 and q.ritmo = 0 then 'apertado'
          when q.ritmo::numeric / 14 * (lim.d - hoje) >= q.em_falta then 'em_dia'
          when q.ritmo::numeric / 14 * (lim.d - hoje) >= q.em_falta * 0.5 then 'apertado'
          else 'em_risco' end,
        'resposta', case
          when ap.n > 0 then 'por_aprovar'
          when pc.id is not null and pc.ultima_resposta is not null then 'respondeu'
          when pc.id is not null and pc.primeiro_contacto is not null then 'sem_resposta'
          when pc.id is null and ult.id is not null and ult.ultima_resposta is not null then 'respondeu'
          when pc.id is null and ult.id is not null and ult.motivo in ('dia_limite', 'sem_contacto') and ult.primeiro_contacto is not null then 'nao_obtida'
          end,
        'sem_resposta_dias', case when pc.primeiro_contacto is not null and pc.ultima_resposta is null then hoje - (pc.primeiro_contacto at time zone 'Europe/Lisbon')::date end
      ) as j
      from public.companies c
      left join public.secretaria_clientes s on s.company_id = c.id
      left join lateral (
        select count(*) filter (where p.estado <> 'anulada') as total,
               count(*) filter (where p.estado in ('recebida', 'associada')) as recebidas,
               count(*) filter (where p.estado = 'pendente') as em_falta,
               count(*) filter (where p.estado in ('recebida', 'associada') and p.recebida_em > now() - interval '14 days') as ritmo
          from public.secretaria_pendencias p where p.company_id = c.id and p.periodo between desde and ate) q on true
      left join lateral (select count(*) as n from public.secretaria_pendencias p where p.company_id = c.id and p.estado = 'pendente') abertas on true
      left join lateral (select count(*) as n from public.secretaria_envios e where e.company_id = c.id and e.estado = 'por_aprovar') ap on true
      left join lateral (select * from public.secretaria_processos p where p.company_id = c.id and p.estado = 'em_curso' limit 1) pc on true
      left join lateral (select * from public.secretaria_processos p where p.company_id = c.id and p.estado = 'terminado' order by p.terminado_em desc limit 1) ult on true
      left join lateral (select coalesce(pc.dia_limite,
        least((date_trunc('month', ate::timestamp) + interval '1 month')::date + (coalesce(s.dia_limite, d.dia_limite) - 1), date '2100-01-01')) as d
        from public.secretaria_definicoes d limit 1) lim on true
      where c.active
    ) x);
end $$;

-- O que um cliente vê: pela ligação do email ou com sessão no portal.
create function public.secretaria_entrega(hash text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.secretaria_envios; p public.secretaria_processos; c public.companies;
begin
  select * into e from public.secretaria_envios where token_hash = hash;
  if not found then return jsonb_build_object('estado', 'invalido'); end if;
  select * into p from public.secretaria_processos where id = e.processo_id;
  select * into c from public.companies where id = p.company_id;
  if p.estado <> 'em_curso' then
    return jsonb_build_object('estado', 'terminado', 'empresa', c.name, 'motivo', p.motivo);
  end if;
  return jsonb_build_object('estado', 'aberto', 'processo', p.id, 'empresa_id', c.id, 'empresa', c.name, 'nif', c.nif, 'dia_limite', p.dia_limite,
    'recebidas', (select count(*) from public.secretaria_pendencias q where q.company_id = c.id and q.estado in ('recebida', 'associada') and q.recebida_em >= p.iniciado_em),
    'pendencias', public.secretaria_pendencias_abertas(c.id));
end $$;

create function public.portal_pendencias(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.secretaria_processos;
begin
  if not public.pode_aceder_empresa(empresa) then raise exception 'Sem acesso' using errcode = '42501'; end if;
  select * into p from public.secretaria_processos x where x.company_id = empresa and x.estado = 'em_curso' and x.primeiro_contacto is not null;
  if not found then return null; end if;
  return jsonb_build_object('processo', p.id, 'dia_limite', p.dia_limite, 'pendencias', public.secretaria_pendencias_abertas(empresa),
    'recebidas', (select count(*) from public.secretaria_pendencias q where q.company_id = empresa and q.estado in ('recebida', 'associada') and q.recebida_em >= p.iniciado_em));
end $$;

create function public.secretaria_doc_registar(empresa uuid, pendencia uuid, p_nome text, p_mime text, p_tamanho bigint, p_original bigint, quem uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q public.secretaria_pendencias;
  novo uuid := gen_random_uuid();
  extensao text;
  mes date := (date_trunc('month', (now() at time zone 'Europe/Lisbon')))::date;
  categoria text := 'outros';
  caminho text;
begin
  if p_mime not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') or p_tamanho not between 1 and 10485760 then
    raise exception 'Ficheiro inválido' using errcode = '22023';
  end if;
  if pendencia is not null then
    select * into q from public.secretaria_pendencias where id = pendencia and company_id = empresa and estado = 'pendente';
    if not found then raise exception 'Este documento já não está em falta' using errcode = '22023'; end if;
    mes := q.periodo;
    categoria := case when q.tipo in ('EB', 'MB') then 'bancos' when q.tipo = 'OUTRO' then 'outros' else 'compras' end;
  end if;
  delete from public.empresa_documentos d
   where d.company_id = empresa and d.enviado_por is not distinct from quem and d.estado = 'pendente' and d.criado_em < now() - interval '6 hours'
     and not exists (select 1 from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho);
  if (select count(*) from public.empresa_documentos d where d.company_id = empresa and d.estado = 'pendente' and d.criado_em > now() - interval '1 day') >= 200 then
    raise exception 'Demasiados envios em curso' using errcode = '54000';
  end if;
  extensao := case p_mime when 'application/pdf' then '.pdf' when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end;
  caminho := empresa::text || '/' || to_char(mes, 'YYYY-MM') || '/' || novo::text || extensao;
  insert into public.empresa_documentos (id, company_id, mes, categoria, nome, caminho, mime, tamanho, tamanho_original, enviado_por, pendencia_id)
  values (novo, empresa, mes, categoria, left(btrim(p_nome), 200), caminho, p_mime, p_tamanho, p_original, quem, pendencia);
  return jsonb_build_object('id', novo, 'caminho', caminho);
end $$;

create function public.secretaria_doc_concluir(documento uuid, quem text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.empresa_documentos; real_tamanho bigint; real_mime text; ficou boolean := false; terminou boolean;
begin
  select * into d from public.empresa_documentos where id = documento for update;
  if not found then raise exception 'Documento indisponível' using errcode = '42501'; end if;
  if d.estado <> 'pendente' then return jsonb_build_object('id', d.id, 'repetido', true); end if;
  select (o.metadata->>'size')::bigint, split_part(coalesce(o.metadata->>'mimetype', ''), ';', 1) into real_tamanho, real_mime
    from storage.objects o where o.bucket_id = 'empresas-documentos' and o.name = d.caminho;
  if not found then raise exception 'O ficheiro ainda não chegou' using errcode = '22023'; end if;
  if real_mime is distinct from d.mime or real_tamanho is null or real_tamanho not between 1 and 10485760 then
    raise exception 'O ficheiro recebido não corresponde ao anunciado' using errcode = '22023';
  end if;
  update public.empresa_documentos set estado = 'recebido', enviado_em = now(), tamanho = real_tamanho where id = d.id;
  if d.pendencia_id is not null then
    update public.secretaria_pendencias set estado = 'recebida', recebida_em = now(), documento_id = d.id
     where id = d.pendencia_id and estado = 'pendente';
    ficou := found;
  end if;
  if not ficou then
    insert into public.secretaria_por_identificar (company_id, documento_id) values (d.company_id, d.id);
  end if;
  update public.secretaria_processos set ultima_resposta = now() where company_id = d.company_id and estado = 'em_curso';
  perform public.registar_empresa(d.company_id, 'documento', 'Documento «' || d.nome || '» entregue a pedido do contabilista');
  perform public.secretaria_registar('Documento recebido', d.company_id, d.nome || case when ficou then '' else ' (por identificar)' end, quem);
  terminou := public.secretaria_fechar_se_completo(d.company_id, 'Sistema');
  return jsonb_build_object('id', d.id, 'empresa', d.company_id, 'associado', ficou, 'terminou', terminou);
end $$;

create function public.secretaria_doc_eliminar(documento uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare caminho_doc text;
begin
  delete from public.empresa_documentos where id = documento and estado = 'pendente' returning caminho into caminho_doc;
  return caminho_doc;
end $$;

create function public.secretaria_responder(p_processo uuid, p_texto text, quem text) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.secretaria_processos;
begin
  update public.secretaria_processos set ultima_resposta = now() where id = p_processo and estado = 'em_curso' returning * into p;
  if not found then raise exception 'Este pedido já terminou' using errcode = '22023'; end if;
  insert into public.secretaria_respostas (processo_id, company_id, texto) values (p.id, p.company_id, left(btrim(p_texto), 2000));
  perform public.secretaria_registar('Resposta do cliente', p.company_id, left(btrim(p_texto), 300), quem);
end $$;

create function public.secretaria_chave_valida(p_chave text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.secretaria_chave c where c.hash = encode(sha256(convert_to(p_chave, 'UTF8')), 'hex'))
$$;

-- Os utilizadores do portal passam a contactos: o primeiro é o principal.
create function public.secretaria_contacto_do_portal() returns trigger
language plpgsql security definer set search_path = '' as $$
declare u record;
begin
  if not new.active then return new; end if;
  select p.email, p.full_name into u from public.profiles p where p.id = new.user_id;
  if u.email is null or u.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then return new; end if;
  insert into public.secretaria_contactos (company_id, nome, email, principal)
  values (new.company_id, left(coalesce(nullif(btrim(u.full_name), ''), u.email), 120), u.email,
          not exists (select 1 from public.secretaria_contactos c where c.company_id = new.company_id and c.principal))
  on conflict do nothing;
  return new;
end $$;
create trigger secretaria_contacto_do_portal after insert on public.company_users
  for each row execute function public.secretaria_contacto_do_portal();

insert into public.secretaria_contactos (company_id, nome, email, principal)
select distinct on (cu.company_id) cu.company_id, left(coalesce(nullif(btrim(p.full_name), ''), p.email), 120), p.email, true
  from public.company_users cu join public.profiles p on p.id = cu.user_id
 where cu.active and p.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
 order by cu.company_id, p.email;

create or replace function public.contagens_do_gabinete()
returns jsonb language sql stable security definer set search_path = '' as $f$
  select case when not public.is_staff() then '{}'::jsonb else jsonb_build_object(
    'a_rever', (select count(*) from public.irs_cases
                 where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
    'alertas', (select count(*) from public.task_alerts where resolved_at is null),
    'por_responder', (
      select count(*) from public.irs_cases c
       where exists(
         select 1 from public.messages m
          where m.case_id = c.id
            and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
            and m.created_at > coalesce((
              select max(m2.created_at) from public.messages m2
               join public.staff_users s2 on s2.user_id = m2.author_id
               where m2.case_id = c.id), '-infinity'::timestamptz))),
    'pagamentos', (select count(*) from public.irs_checkouts k
                    where k.state = 'paid'
                      and k.paid_at > coalesce(public.visto_em('gestao:pagamentos'), now() - interval '7 days')),
    'sem_pagamento', (select count(*) from public.clientes_sem_pagamento(7)),
    'desistencias', (select count(*) from public.pedidos_desistencia where estado = 'pendente'),
    'empresas', (select count(*) from public.empresa_mensagens m where not m.do_gabinete and m.lida_em is null)
              + (select count(*) from public.empresa_documentos d where d.estado = 'recebido')
              + (select count(*) from public.empresa_pessoal p where p.estado = 'novo'),
    'secretaria_aprovar', (select count(*) from public.secretaria_envios e where e.estado = 'por_aprovar'),
    'secretaria_identificar', (select count(*) from public.secretaria_por_identificar p where p.estado = 'por_rever'),
    'secretaria_falhas', (select count(*) from public.secretaria_envios e where e.estado = 'falhou')
  ) end
$f$;

do $x$
declare d text; f regprocedure;
begin
  d := pg_get_functiondef('public.novidades_empresa(uuid)'::regprocedure);
  d := replace(d, $a$'pessoal', (select count(*) from public.empresa_pessoal p$a$,
$a$'em_falta', coalesce(jsonb_array_length((public.portal_pendencias(empresa))->'pendencias'), 0),
    'pessoal', (select count(*) from public.empresa_pessoal p$a$);
  if d not like '%''em_falta''%' then raise exception 'novidades_empresa: texto não encontrado'; end if;
  execute d;

  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace
            and (p.proname like 'secretaria\_%' or p.proname = 'portal_pendencias') loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $x$;

-- As que o contabilista chama da consola. As outras ficam só para o servidor.
grant execute on function public.secretaria_auditar(text, uuid, text) to authenticated;
grant execute on function public.secretaria_auditoria_verificar() to authenticated;
grant execute on function public.secretaria_gerar_recorrentes(date) to authenticated;
grant execute on function public.secretaria_iniciar_processo(uuid, date, boolean) to authenticated;
grant execute on function public.secretaria_cancelar_processo(uuid) to authenticated;
grant execute on function public.secretaria_decidir_envio(uuid, boolean, text, text) to authenticated;
grant execute on function public.secretaria_repetir_envio(uuid) to authenticated;
grant execute on function public.secretaria_pendencias_acao(uuid[], text) to authenticated;
grant execute on function public.secretaria_arquivar_documento(uuid, uuid) to authenticated;
grant execute on function public.secretaria_marcar_revisto(uuid) to authenticated;
grant execute on function public.secretaria_painel() to authenticated;
grant execute on function public.secretaria_clientes_resumo(date, date) to authenticated;
grant execute on function public.portal_pendencias(uuid) to authenticated;

commit;
