-- Os emails que as plataformas enviam: ao cliente (pedidos de pagamento,
-- reembolsos, pagamentos recebidos, mensagens, etapas) e ao gabinete.
--
-- Cada email tem uma chave: "pago:<pagamento>", "reembolso:<id>"... A chave é
-- única, por isso o mesmo aviso nunca sai duas vezes — o webhook da Stripe e a
-- página de regresso confirmam o mesmo pagamento, e só um deles envia. Fica
-- também a prova do que foi comunicado e quando, para o relatório de atividade.
begin;

create table if not exists public.emails (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,
  para text not null,
  assunto text not null,
  account_id uuid references public.client_accounts(id) on delete cascade,
  case_id uuid references public.irs_cases(id) on delete cascade,
  estado text not null default 'a_enviar' check (estado in ('a_enviar','enviado','falhou')),
  resend_id text,
  erro text,
  criado_em timestamptz not null default now(),
  enviado_em timestamptz
);
create index if not exists emails_case on public.emails(case_id);
create index if not exists emails_account on public.emails(account_id);
alter table public.emails enable row level security;
-- Só o servidor lê e escreve: nem o cliente nem o anon têm acesso direto.
revoke all on public.emails from anon, authenticated;

do $x$
declare d text;
begin
  d := pg_get_functiondef('public.relatorio_de_atividade(uuid)'::regprocedure);
  if position('''email''' in d) = 0 then
    d := replace(d, $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'$q$,
                    $q$when 'pagamento_iniciado' then 'Pagamento aberto pelo cliente'
                 when 'email' then 'Email enviado ao cliente'$q$);
    execute d;
  end if;
end $x$;

commit;
