-- O membro do agregado e a sua senha das Finanças passam a ser gravados na
-- mesma transação. Antes eram duas chamadas: se a segunda falhasse, o membro
-- ficava sem senha e o cliente via um erro a meio. A senha tem de ser indicada
-- ao criar o membro — é a regra do gabinete — e pode ser substituída depois.
--
-- O id de um membro novo vem de fora (p_id_novo) porque a senha é cifrada no
-- servidor da aplicação com o id da pessoa no AAD, antes de chegar aqui.
begin;

drop function if exists public.guardar_membro_agregado(uuid, text, text, text, uuid, date, boolean);

create or replace function public.guardar_membro_agregado(
  processo uuid, p_nome text, p_nif text, p_relacao text,
  p_pessoa uuid default null, p_nascimento date default null,
  p_dois_fatores boolean default false,
  p_id_novo uuid default null, p_cifrada text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  destino uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_edit_case(conta, processo) then
    raise exception 'O processo não pode ser alterado neste momento.' using errcode = '42501';
  end if;
  if p_nome is null or length(btrim(p_nome)) < 2 then
    raise exception 'Indique o nome completo.' using errcode = '22023';
  end if;
  if p_nif !~ '^[0-9]{9}$' then
    raise exception 'O NIF tem nove dígitos.' using errcode = '22023';
  end if;
  if p_nascimento is null then
    raise exception 'Indique a data de nascimento.' using errcode = '22023';
  end if;
  if p_nascimento > current_date then
    raise exception 'A data de nascimento não pode ser no futuro.' using errcode = '22023';
  end if;
  if p_relacao not in ('titular','conjuge','descendente','ascendente','outro') then
    raise exception 'Escolha a relação de parentesco.' using errcode = '22023';
  end if;

  if p_pessoa is null then
    if p_cifrada is null or p_id_novo is null then
      raise exception 'Indique a senha do Portal das Finanças desta pessoa.' using errcode = '22023';
    end if;
    if exists(select 1 from public.case_people cp join public.people p on p.id = cp.person_id
               where cp.case_id = processo and p.nif = p_nif) then
      raise exception 'Já existe alguém com este NIF no agregado.' using errcode = '23505';
    end if;
    insert into public.people(id, account_id, full_name, birth_date, nif, tax_two_factor)
      values (p_id_novo, conta, btrim(p_nome), p_nascimento, p_nif, p_dois_fatores)
      returning id into destino;
  else
    update public.people
       set full_name = btrim(p_nome), birth_date = p_nascimento,
           nif = p_nif, tax_two_factor = p_dois_fatores
     where id = p_pessoa and account_id = conta
     returning id into destino;
    if destino is null then
      raise exception 'Membro não encontrado nesta conta.' using errcode = '22023';
    end if;
    if p_cifrada is null and not exists(select 1 from public.tax_credentials where person_id = destino) then
      raise exception 'Indique a senha do Portal das Finanças desta pessoa.' using errcode = '22023';
    end if;
  end if;

  insert into public.case_people(account_id, case_id, person_id, relationship)
    values (conta, processo, destino, p_relacao)
    on conflict (case_id, person_id) do update set relationship = excluded.relationship;

  if p_cifrada is not null then
    insert into public.tax_credentials(person_id, account_id, encrypted_password, updated_at, updated_by)
      values (destino, conta, p_cifrada, now(), auth.uid())
    on conflict (person_id) do update
      set encrypted_password = excluded.encrypted_password,
          updated_at = now(), updated_by = excluded.updated_by;
  end if;

  return destino;
end $$;

revoke all on function public.guardar_membro_agregado(uuid,text,text,text,uuid,date,boolean,uuid,text) from public, anon;
grant execute on function public.guardar_membro_agregado(uuid,text,text,text,uuid,date,boolean,uuid,text) to authenticated;

-- O titular da minha conta, para a senha do onboarding. Sem RLS pelo meio:
-- no próprio pedido em que o perfil acabou de ser criado, a leitura através
-- das políticas era o elo frágil.
create or replace function public.meu_titular()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('processo', c.id, 'pessoa', cp.person_id)
    from public.account_access a
    join public.irs_cases c on c.account_id = a.account_id
    join public.case_people cp on cp.case_id = c.id and cp.relationship = 'titular'
   where a.user_id = auth.uid() and a.role = 'owner' and a.active
   order by c.tax_year desc
   limit 1
$$;

revoke all on function public.meu_titular() from public, anon;
grant execute on function public.meu_titular() to authenticated;
revoke all on function public.guardar_senha_financas(uuid,uuid,text) from public, anon;
grant execute on function public.guardar_senha_financas(uuid,uuid,text) to authenticated;

commit;
