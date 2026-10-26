-- Deteta se um NIF já está em uso e diz de que tipo é o conflito, para o
-- onboarding poder explicar em vez de falhar com uma violação de unicidade.
--
-- Não devolve nomes nem emails de terceiros: só o tipo de conflito e se a
-- conta do outro lado já tem histórico a sério. Quem escreve um NIF que não
-- é seu não fica a saber de quem ele é.
begin;

create or replace function public.conflito_de_nif(contribuinte text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  eu uuid := auth.uid();
  minha_conta uuid;
  dono uuid;
  pessoa record;
  com_historico boolean;
begin
  if eu is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if contribuinte !~ '^[0-9]{9}$' then
    return jsonb_build_object('tipo', 'invalido');
  end if;

  select account_id into minha_conta
    from public.account_access where user_id = eu order by role limit 1;

  select id into dono from public.profiles
   where nif = contribuinte and id <> eu and deleted_at is null limit 1;

  if dono is not null then
    select exists(
      select 1 from public.irs_cases c
       join public.account_access a on a.account_id = c.account_id
       where a.user_id = dono
         and (c.status <> 'collecting'
              or exists(select 1 from public.irs_checkouts k
                         where k.case_id = c.id and k.state = 'paid'))
    ) into com_historico;
    return jsonb_build_object('tipo', 'conta', 'com_historico', coalesce(com_historico, false));
  end if;

  select p.id, cp.relationship, cp.case_id, p.account_id
    into pessoa
    from public.people p
    join public.case_people cp on cp.person_id = p.id
   where p.nif = contribuinte
     and (minha_conta is null or p.account_id <> minha_conta)
   limit 1;

  if pessoa.id is not null then
    select exists(
      select 1 from public.irs_cases c
       where c.id = pessoa.case_id
         and (c.status <> 'collecting'
              or exists(select 1 from public.irs_checkouts k
                         where k.case_id = c.id and k.state = 'paid'))
    ) into com_historico;
    return jsonb_build_object(
      'tipo', case when pessoa.relationship = 'titular' then 'conta' else 'agregado' end,
      'relacao', pessoa.relationship,
      'com_historico', coalesce(com_historico, false));
  end if;

  return jsonb_build_object('tipo', 'nenhum');
end $$;

-- O alerta que fica para o gabinete quando há conflito.
create or replace function public.alertar_conflito_de_nif(contribuinte text, tipo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare conta uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select account_id into conta from public.account_access
   where user_id = auth.uid() order by role limit 1;
  if conta is null then return; end if;

  -- Um alerta por conta e por tipo: repetir a tentativa não enche a fila.
  if exists(select 1 from public.task_alerts
             where account_id = conta and kind = 'nif_' || tipo and resolved_at is null) then
    return;
  end if;
  insert into public.task_alerts(account_id, kind) values (conta, 'nif_' || tipo);
end $$;

commit;
