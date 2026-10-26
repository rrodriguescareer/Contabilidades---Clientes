-- Preços, campanhas e avisos deixam de viver em código.
-- A política semeia-se com os valores que já estavam na função, para o preço
-- não mudar no dia em que isto entra.
begin;

create table if not exists public.pricing_policies (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  activa boolean not null default false,
  valores jsonb not null,
  notas text not null default '',
  criada_em timestamptz not null default now(),
  criada_por uuid references auth.users(id)
);
alter table public.pricing_policies drop constraint if exists pricing_policies_nome_check;
alter table public.pricing_policies add constraint pricing_policies_nome_check
  check (length(nome) between 2 and 120);

-- Só uma política activa de cada vez: duas seria o preço a depender da sorte.
create unique index if not exists pricing_policies_uma_activa
  on public.pricing_policies ((activa)) where activa;

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  rotulo_publico text not null,
  tipo text not null,
  valor integer not null,
  activa boolean not null default false,
  inicio timestamptz,
  fim timestamptz,
  criada_em timestamptz not null default now(),
  criada_por uuid references auth.users(id)
);
alter table public.campaigns drop constraint if exists campaigns_tipo_check;
alter table public.campaigns add constraint campaigns_tipo_check
  check (tipo in ('percentagem','fixo'));
alter table public.campaigns drop constraint if exists campaigns_valor_check;
alter table public.campaigns add constraint campaigns_valor_check
  check (valor > 0 and (tipo <> 'percentagem' or valor <= 100));
alter table public.campaigns drop constraint if exists campaigns_janela_check;
alter table public.campaigns add constraint campaigns_janela_check
  check (inicio is null or fim is null or fim > inicio);
alter table public.campaigns drop constraint if exists campaigns_nomes_check;
alter table public.campaigns add constraint campaigns_nomes_check
  check (length(nome) between 2 and 120 and length(rotulo_publico) between 2 and 160);

create table if not exists public.avisos (
  id uuid primary key default gen_random_uuid(),
  mensagem text not null,
  tom text not null default 'info',
  activo boolean not null default false,
  inicio timestamptz,
  fim timestamptz,
  no_irs boolean not null default true,
  no_website boolean not null default false,
  criado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id)
);
alter table public.avisos drop constraint if exists avisos_mensagem_check;
alter table public.avisos add constraint avisos_mensagem_check
  check (length(mensagem) between 5 and 400);
alter table public.avisos drop constraint if exists avisos_tom_check;
alter table public.avisos add constraint avisos_tom_check
  check (tom in ('info','atencao','critico'));
alter table public.avisos drop constraint if exists avisos_janela_check;
alter table public.avisos add constraint avisos_janela_check
  check (inicio is null or fim is null or fim > inicio);

alter table public.pricing_policies enable row level security;
alter table public.campaigns enable row level security;
alter table public.avisos enable row level security;

drop policy if exists politica_gabinete on public.pricing_policies;
drop policy if exists campanha_gabinete on public.campaigns;
drop policy if exists aviso_gabinete on public.avisos;
drop policy if exists aviso_publico on public.avisos;

-- Preços e campanhas: só o gabinete mexe. O cliente vê o efeito no orçamento,
-- não a tabela.
create policy politica_gabinete on public.pricing_policies
  for all using (public.is_staff()) with check (public.is_staff());
create policy campanha_gabinete on public.campaigns
  for all using (public.is_staff()) with check (public.is_staff());
create policy aviso_gabinete on public.avisos
  for all using (public.is_staff()) with check (public.is_staff());

-- Os avisos activos são públicos: é esse o objectivo deles.
create policy aviso_publico on public.avisos
  for select using (
    activo
    and (inicio is null or inicio <= now())
    and (fim is null or fim > now())
  );

/* Os valores em vigor. Se não houver política activa, valem os que estavam
   na função — o preço nunca fica indefinido. */
create or replace function public.precos_em_vigor()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select valores from public.pricing_policies where activa limit 1),
    '{"base":1850,"varios_titulares":500,"a_e_b":1500,"b_adicional":500,
      "rendas_unica":0,"rendas_ate2":500,"rendas_ate5":1000,"rendas_mais":2000,
      "mais_valias_titulos":1000,"mais_valias_imovel":1000}'::jsonb)
$$;

/** A campanha em vigor, se houver. */
create or replace function public.campanha_em_vigor()
returns public.campaigns
language sql
stable
set search_path = ''
as $$
  select * from public.campaigns
   where activa
     and (inicio is null or inicio <= now())
     and (fim is null or fim > now())
   order by criada_em desc limit 1
$$;

commit;
