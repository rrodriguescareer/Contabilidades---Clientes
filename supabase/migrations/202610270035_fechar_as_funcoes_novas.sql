-- As funções novas ficaram executáveis pelo anon do PostgREST: o Supabase tem
-- um default privilege no schema public que dá execute ao anon em cada função
-- criada, por isso o "revoke from public" do core não chega — é preciso tirar
-- ao anon pelo nome. As três verificam a autorização por dentro, mas uma função
-- que só serve quem está autenticado não deve estar à porta.
begin;

revoke all on function
  public.prontidao_do_processo(uuid),
  public.submeter_processo(uuid),
  public.espaco_progresso(uuid)
from public, anon;

grant execute on function
  public.prontidao_do_processo(uuid),
  public.submeter_processo(uuid),
  public.espaco_progresso(uuid)
to authenticated;

commit;
