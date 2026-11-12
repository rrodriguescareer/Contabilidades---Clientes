-- No portal IRS, dois botões «Remover» não removiam: o do membro do agregado
-- e o do rendimento. Em ambos, o cliente via um erro em inglês da base.
--
-- 1. O membro do agregado.
--
-- A função corria com as permissões de quem chama, e os clientes só têm
-- leitura em case_people: o DELETE não encontrava linhas e terminava sem erro.
-- O portal dizia «removido» e o membro continuava lá. (A função tinha sido
-- criada diretamente na base em outubro e nunca chegou a estas migrações.)
--
-- Passa a correr como as outras do agregado: verifica à mão que o processo é
-- de quem chama e que ainda pode ser alterado, e só então remove. O titular
-- não se remove, e um membro com rendimentos também não: primeiro os
-- rendimentos. Se a pessoa não ficar em nenhum processo, sai também a ficha e
-- a senha das Finanças — não se guardam dados de quem já não faz parte.
begin;

drop function if exists public.remover_membro_agregado(uuid, uuid);

create function public.remover_membro_agregado(processo uuid, pessoa uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  relacao text;
begin
  select account_id into conta from public.irs_cases where id = processo;
  if conta is null or not public.can_edit_case(conta, processo) then
    raise exception 'O processo não pode ser alterado neste momento.' using errcode = '42501';
  end if;
  select relationship into relacao
    from public.case_people where case_id = processo and person_id = pessoa and account_id = conta;
  if relacao is null then
    raise exception 'Membro não encontrado neste processo.' using errcode = '22023';
  end if;
  if relacao = 'titular' then
    raise exception 'O titular do processo não pode ser removido.' using errcode = '22023';
  end if;
  if exists (select 1 from public.income_records where case_id = processo and person_id = pessoa) then
    raise exception 'Este membro tem rendimentos associados. Remova-os primeiro.' using errcode = '22023';
  end if;

  delete from public.case_people where case_id = processo and person_id = pessoa;

  if not exists (select 1 from public.case_people where person_id = pessoa) then
    begin
      delete from public.people where id = pessoa and account_id = conta;
    exception when others then
      null; -- há histórico desta pessoa (convites, documentos): a ficha fica
    end;
  end if;
end $$;

revoke all on function public.remover_membro_agregado(uuid, uuid) from public, anon;
grant execute on function public.remover_membro_agregado(uuid, uuid) to authenticated, service_role;

-- 2. O rendimento. Os clientes podiam criar rendimentos mas não apagá-los: a
-- tabela só lhes dava leitura e inserção. Passam a poder apagar os do próprio
-- processo, enquanto ele pode ser alterado — a mesma regra da inserção, e o
-- mesmo travão (guard_case_collection) quando o processo já foi submetido ou
-- tem um pagamento a decorrer.
grant delete on public.income_records to authenticated;
drop policy if exists resource_delete on public.income_records;
create policy resource_delete on public.income_records for delete to authenticated
  using (public.can_edit_case(account_id, case_id));

commit;
