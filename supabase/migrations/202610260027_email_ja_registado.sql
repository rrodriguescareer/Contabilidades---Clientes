-- O Supabase não diz se um email já existe — protege contra enumeração de
-- contas. O efeito colateral é que o registo repetido parece correr bem e o
-- email de confirmação nunca chega.
--
-- Esta função diz apenas se o endereço já tem conta. Não devolve o
-- utilizador nem o estado dele. Só a chave de serviço lhe chega: sem GRANT
-- para anon ou authenticated, ninguém a pode usar para varrer endereços.
begin;

create or replace function public.email_ja_registado(endereco text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from auth.users
     where lower(email) = lower(btrim(endereco))
       and deleted_at is null
  )
$$;

revoke all on function public.email_ja_registado(text) from public, anon, authenticated;

commit;
