-- As contagens do menu lateral da gestão, que agora tem o gabinete do IRS
-- dentro: o que espera por mim, as conversas por responder e os alertas.
-- Corre em cada página, por isso é só isto — nada da fila inteira.
begin;

create or replace function public.contagens_do_gabinete()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.is_staff() then '{}'::jsonb else jsonb_build_object(
    'a_rever', (select count(*) from public.irs_cases
                 where status in ('submitted_by_client','accepted','validation','approved','submitting','divergence')),
    'alertas', (select count(*) from public.task_alerts where resolved_at is null),
    'por_responder', (
      select count(*) from public.irs_cases c
       where exists(
         select 1 from public.messages m
          where m.case_id = c.id
            and not exists(select 1 from public.staff_users s where s.user_id = m.author_id)
            and m.created_at > coalesce((
              select max(m2.created_at) from public.messages m2
               join public.staff_users s2 on s2.user_id = m2.author_id
               where m2.case_id = c.id), '-infinity'::timestamptz)))
  ) end
$$;

revoke all on function public.contagens_do_gabinete() from public, anon;
grant execute on function public.contagens_do_gabinete() to authenticated;

commit;
