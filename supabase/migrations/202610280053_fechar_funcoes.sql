-- Revisão de segurança das funções.
--
-- 1. Crítico: finalizar_pagamento_stripe e anexar_sessao_de_pagamento podiam
--    ser chamadas por qualquer cliente autenticado (e até sem sessão). Um
--    cliente sabe o id da tentativa, o valor e o id da sessão do Stripe — ou
--    anexava um id inventado e depois "finalizava" com ele. Dava para marcar
--    o processo como pago sem pagar. Passam a ser só do servidor.
-- 2. O anon (quem não entrou) podia executar 24 funções, 17 delas com
--    privilégios de definidor. Nenhuma página pública precisa de nenhuma.
--    Fecham-se todas, e também as que vierem a ser criadas.
-- 3. As políticas que chamam funções aplicavam-se também ao anon; ficam só
--    para quem entrou (o anon continua a ler os avisos públicos).
begin;

revoke all on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) from public, anon, authenticated;
grant execute on function public.finalizar_pagamento_stripe(uuid,text,text,boolean,boolean,integer,text) to service_role;
revoke all on function public.anexar_sessao_de_pagamento(uuid,text,text) from public, anon, authenticated;
grant execute on function public.anexar_sessao_de_pagamento(uuid,text,text) to service_role;

do $x$
declare f record;
begin
  for f in
    select p.oid, p.oid::regprocedure as assinatura from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  loop
    -- Quem entrou e o servidor mantêm o que já tinham, mesmo que lhes viesse
    -- só pela concessão a public.
    if has_function_privilege('authenticated', f.oid, 'execute') then
      execute format('grant execute on function %s to authenticated', f.assinatura);
    end if;
    if has_function_privilege('service_role', f.oid, 'execute') then
      execute format('grant execute on function %s to service_role', f.assinatura);
    end if;
    execute format('revoke execute on function %s from public, anon', f.assinatura);
  end loop;
end $x$;
alter default privileges in schema public revoke execute on functions from public, anon;

do $x$
declare p record;
begin
  for p in
    select c.relname as tabela, po.polname as politica
      from pg_policy po join pg_class c on c.oid = po.polrelid join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and 0 = any(po.polroles)
       and coalesce(pg_get_expr(po.polqual, po.polrelid), '') || coalesce(pg_get_expr(po.polwithcheck, po.polrelid), '')
           ~ '(is_staff|can_read_account|can_edit_case|readable_accounts)\('
  loop
    execute format('alter policy %I on public.%I to authenticated', p.politica, p.tabela);
  end loop;
end $x$;

commit;
