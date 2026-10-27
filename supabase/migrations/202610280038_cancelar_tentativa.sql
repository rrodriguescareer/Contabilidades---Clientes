-- Fecha uma tentativa de pagamento que o servidor não conseguiu abrir no
-- Stripe (ou cuja sessão expirou), para a seguinte começar limpa. Só a chave
-- de serviço: é o servidor que decide, depois de falar com o Stripe.
begin;

create or replace function public.cancelar_tentativa_de_pagamento(attempt uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.irs_checkouts set state = 'cancelled'
   where id = attempt and state in ('creating','pending','unknown');
$$;

revoke all on function public.cancelar_tentativa_de_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.cancelar_tentativa_de_pagamento(uuid) to service_role;

commit;
