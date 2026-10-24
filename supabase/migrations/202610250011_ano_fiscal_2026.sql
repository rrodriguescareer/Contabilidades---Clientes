-- A campanha IRS 2026 entrega-se em maio de 2027, logo o ano dos rendimentos
-- é 2026. Os processos tinham ficado com tax_year 2025, herdado de quando a
-- campanha era calculada a partir do ano corrente.
--
-- O `campaign` já era 2026 e é por ele que o portal filtra, por isso nada
-- estava partido — mas o ano fiscal gravado contradizia o que a plataforma
-- diz ao cliente.

begin;

update public.irs_cases set tax_year = 2026 where campaign = 2026 and tax_year <> 2026;

-- save_personal_profile abre o processo do cliente no primeiro acesso e tinha
-- o ano fixado em 2025. Reescreve-se o corpo em vez de o repetir aqui, para a
-- função não divergir do resto da sua definição.
do $ano$
declare definicao text;
begin
  select pg_get_functiondef(
    'public.save_personal_profile(text,date,text,text,text,text,text,boolean)'::regprocedure
  ) into definicao;

  if position('values(account,2025)' in definicao) = 0 then
    raise exception 'save_personal_profile já não fixa o ano em 2025; reveja a migração antes de a aplicar';
  end if;

  execute replace(definicao, 'values(account,2025)', 'values(account,2026)');
end $ano$;

commit;
