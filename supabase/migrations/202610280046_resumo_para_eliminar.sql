-- O resumo de cada utilizador de uma página da lista, numa consulta só: se
-- confirmou o email, o que tem (processos, rendimentos, documentos,
-- mensagens) e se pagou — para a confirmação da eliminação dizer o que se
-- vai perder e avisar quando há um pagamento que pode ser contestado.
begin;

drop function if exists public.antes_de_eliminar(uuid);

create or replace function public.resumo_para_eliminar(ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.is_staff() then '{}'::jsonb else coalesce(jsonb_object_agg(u.id, jsonb_build_object(
    'confirmado', u.email_confirmed_at is not null,
    'ultimo_acesso', u.last_sign_in_at,
    'processos', (select count(*) from public.irs_cases c join public.account_access a on a.account_id = c.account_id
                   where a.user_id = u.id and a.role = 'owner'),
    'rendimentos', (select count(*) from public.income_records r join public.account_access a on a.account_id = r.account_id
                     where a.user_id = u.id and a.role = 'owner'),
    'documentos', (select count(*) from public.documents d join public.account_access a on a.account_id = d.account_id
                    where a.user_id = u.id and a.role = 'owner'),
    'mensagens', (select count(*) from public.messages m join public.account_access a on a.account_id = m.account_id
                   where a.user_id = u.id and a.role = 'owner'),
    'pago_em', (select max(k.paid_at) from public.irs_checkouts k join public.account_access a on a.account_id = k.account_id
                 where a.user_id = u.id and a.role = 'owner' and k.state = 'paid'),
    'processo', (select c.id from public.irs_cases c join public.account_access a on a.account_id = c.account_id
                  where a.user_id = u.id and a.role = 'owner' order by c.tax_year desc limit 1)
  )), '{}'::jsonb) end
  from auth.users u where u.id = any(ids)
$$;

revoke all on function public.resumo_para_eliminar(uuid[]) from public, anon;
grant execute on function public.resumo_para_eliminar(uuid[]) to authenticated;

commit;
