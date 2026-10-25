-- Dar acesso de IRS ou de Empresas a um utilizador, criando a conta-cliente
-- quando ela ainda não existe.
--
-- O cliente de IRS cria-se a si próprio no registo, e nessa altura ganha conta
-- e acesso. O cliente de Empresas é criado pelo contabilista e pode nunca ter
-- tido conta nenhuma. Quando um quer o módulo do outro, é aqui que se resolve:
-- sem conta, cria-se; com conta, muda-se o que está marcado.
--
-- As empresas em si continuam a associar-se no módulo Empresas: isto marca
-- apenas que a pessoa tem acesso à plataforma.

begin;

create or replace function public.definir_acessos(target uuid, com_irs boolean, com_empresas boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare conta uuid; nome text;
begin
  if not public.is_platform_owner() then
    raise exception 'Apenas o administrador atribui acessos' using errcode = '42501';
  end if;
  if target is null or not exists (select 1 from public.profiles where id = target) then
    raise exception 'Utilizador desconhecido' using errcode = '22023';
  end if;

  select a.account_id into conta
  from public.account_access a
  where a.user_id = target and a.role = 'owner'
  limit 1;

  if conta is null then
    if not com_irs and not com_empresas then return null; end if;

    select coalesce(nullif(btrim(p.full_name), ''), p.email, 'Cliente')
      into nome from public.profiles p where p.id = target;

    insert into public.client_accounts(name) values (left(nome, 200)) returning id into conta;
    insert into public.account_access(account_id, user_id, role, irs, business, active)
    values (conta, target, 'owner', com_irs, com_empresas, true);
  else
    update public.account_access
    set irs = com_irs, business = com_empresas
    where account_id = conta and user_id = target;
  end if;

  insert into public.management_audit(actor_id, target_id, action)
  values (auth.uid(), target,
          'acessos: irs=' || com_irs::text || ' empresas=' || com_empresas::text);

  return conta;
end $$;

revoke all on function public.definir_acessos(uuid, boolean, boolean) from public, anon;
grant execute on function public.definir_acessos(uuid, boolean, boolean) to authenticated;

commit;
