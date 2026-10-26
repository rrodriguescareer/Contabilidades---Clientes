-- Três defeitos no mesmo sítio, todos encontrados a testar:
--
-- 1. O parâmetro chamava-se nif, como a coluna. "nif = nif" num UPDATE é
--    ambíguo e o Postgres recusa: editar um membro — incluindo ligar o 2FA —
--    falhava sempre.
--
-- 2. A função corria com as permissões de quem chama, e o papel authenticated
--    não tem UPDATE em people nem INSERT em tax_credentials. Passam a
--    security definer, com a autorização verificada à mão.
--
-- 3. birth_date é obrigatório na tabela e é dele que depende o IRS Jovem,
--    mas nada o exigia: rebentava numa violação de not-null sem explicação.
begin;

drop function if exists public.guardar_membro_agregado(uuid, text, text, text, uuid, date, boolean);

create or replace function public.guardar_membro_agregado(
  processo uuid,
  p_nome text,
  p_nif text,
  p_relacao text,
  p_pessoa uuid default null,
  p_nascimento date default null,
  p_dois_fatores boolean default false
) returns uuid
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
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_nome is null or length(btrim(p_nome)) < 2 then
    raise exception 'Indique o nome completo.';
  end if;
  if p_nif !~ '^[0-9]{9}$' then
    raise exception 'O NIF tem nove digitos.';
  end if;
  if p_nascimento is null then
    raise exception 'Indique a data de nascimento: e dela que depende o IRS Jovem.';
  end if;
  if p_nascimento > current_date then
    raise exception 'A data de nascimento nao pode ser no futuro.';
  end if;
  if p_relacao not in ('titular','conjuge','descendente','ascendente','outro') then
    raise exception 'Relacao invalida.';
  end if;

  if p_pessoa is null then
    insert into public.people(account_id, full_name, birth_date, nif, tax_two_factor)
      values (conta, btrim(p_nome), p_nascimento, p_nif, p_dois_fatores)
      returning id into destino;
  else
    update public.people
       set full_name = btrim(p_nome),
           birth_date = p_nascimento,
           nif = p_nif,
           tax_two_factor = p_dois_fatores
     where id = p_pessoa and account_id = conta
     returning id into destino;
    if destino is null then
      raise exception 'Membro nao encontrado nesta conta.';
    end if;
  end if;

  insert into public.case_people(account_id, case_id, person_id, relationship)
    values (conta, processo, destino, p_relacao)
    on conflict (case_id, person_id) do update set relationship = excluded.relationship;

  return destino;
end $$;

create or replace function public.guardar_senha_financas(
  processo uuid,
  p_pessoa uuid,
  p_cifrada text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_read_account(conta) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists(select 1 from public.case_people
                 where case_id = processo and person_id = p_pessoa) then
    raise exception 'Membro nao pertence a este processo.';
  end if;

  insert into public.tax_credentials(person_id, account_id, encrypted_password, updated_at, updated_by)
    values (p_pessoa, conta, p_cifrada, now(), auth.uid())
  on conflict (person_id) do update
    set encrypted_password = excluded.encrypted_password,
        updated_at = now(),
        updated_by = excluded.updated_by;
end $$;

commit;
