-- O onboarding passa a recolher a residência fiscal e, fora da UE, o
-- representante. A senha das Finanças não entra aqui: é cifrada pela
-- aplicação e escrita na tax_credentials, para nunca passar por esta função.
begin;

create or replace function public.guardar_residencia_fiscal(
  residencia text,
  rep_nome text default null,
  rep_contribuinte text default null,
  rep_email text default null,
  rep_telefone text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if residencia is null or residencia not in ('continente','acores','madeira','ue','fora_ue') then
    raise exception 'Indique a residencia fiscal.';
  end if;
  if residencia = 'fora_ue'
     and (nullif(trim(coalesce(rep_nome,'')),'') is null
          or nullif(trim(coalesce(rep_contribuinte,'')),'') is null
          or (nullif(trim(coalesce(rep_email,'')),'') is null
              and nullif(trim(coalesce(rep_telefone,'')),'') is null)) then
    raise exception 'Fora da UE e obrigatorio indicar o representante fiscal e um contacto.';
  end if;

  update public.profiles
     set tax_residence = residencia,
         rep_name = case when residencia = 'fora_ue' then nullif(trim(rep_nome),'') end,
         rep_nif = case when residencia = 'fora_ue' then nullif(trim(rep_contribuinte),'') end,
         rep_email = case when residencia = 'fora_ue' then nullif(trim(rep_email),'') end,
         rep_phone = case when residencia = 'fora_ue' then nullif(trim(rep_telefone),'') end
   where id = auth.uid();
end $$;

-- A pessoa do titular, para a aplicação saber onde guardar a senha.
create or replace function public.pessoa_titular(processo uuid)
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select cp.person_id from public.case_people cp
   where cp.case_id = processo and cp.relationship = 'titular' limit 1
$$;

commit;
