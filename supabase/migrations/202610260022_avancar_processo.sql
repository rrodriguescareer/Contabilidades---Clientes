-- O avanço do processo pelo contabilista, com transições validadas.
begin;

-- Quem muda o estado não tem de se lembrar de carimbar a data. Um gatilho
-- faz isso sempre, venha a mudança de onde vier.
create or replace function public.carimbar_estado()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
    if new.status = 'submitted_by_client' and new.submitted_by_client_at is null then
      new.submitted_by_client_at := now();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists carimbar_estado on public.irs_cases;
create trigger carimbar_estado before update on public.irs_cases
for each row execute function public.carimbar_estado();

-- As transições possíveis a partir de cada estado. Fora desta tabela, não há.
create or replace function public.transicoes_do_estado(actual text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case actual
    when 'collecting'          then array['submitted_by_client']
    when 'submitted_by_client' then array['accepted','collecting']
    when 'accepted'            then array['validation','collecting']
    when 'validation'          then array['approved','collecting']
    when 'approved'            then array['submitting','validation']
    when 'submitting'          then array['filed','approved']
    when 'filed'               then array['monitoring']
    when 'monitoring'          then array['closed','filed']
    when 'closed'              then array['monitoring']
    else array[]::text[] end
$$;

/* O avanço do processo pelo contabilista.
   Valida a transição, carimba o valor apurado quando chega à submissão, e
   deixa sempre um evento para o cliente ver no acompanhamento. */
create or replace function public.avancar_processo(
  processo uuid,
  destino text,
  nota text default '',
  valor_cents bigint default null,
  sentido text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  conta uuid;
  actual text;
  rotulos jsonb := jsonb_build_object(
    'submitted_by_client','Processo submetido',
    'accepted','Processo aceite',
    'validation','Em validação',
    'approved','Aprovado',
    'submitting','Em processo de submissão',
    'filed','Submetido na Autoridade Tributária',
    'monitoring','Em acompanhamento',
    'closed','Processo fechado',
    'collecting','Devolvido para completar');
  -- O corpo do evento nunca pode ficar vazio: sem nota, explica-se o passo.
  corpos jsonb := jsonb_build_object(
    'submitted_by_client','O processo foi submetido e entrou na minha fila.',
    'accepted','Recebi o processo e abri-o para análise.',
    'validation','Estou a conferir os rendimentos e os documentos.',
    'approved','Está tudo conferido. O processo segue para submissão.',
    'submitting','A declaração está a ser entregue na Autoridade Tributária.',
    'filed','A declaração foi entregue.',
    'monitoring','À espera da validação da Autoridade Tributária.',
    'closed','O processo está concluído.',
    'collecting','Faltam elementos. A recolha foi reaberta.');
begin
  if not public.is_staff() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select account_id, status into conta, actual
    from public.irs_cases where id = processo for update;
  if conta is null then
    raise exception 'Processo nao encontrado.';
  end if;

  if not (destino = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, destino;
  end if;

  -- O valor apurado só faz sentido na entrega, e aí é obrigatório.
  if destino = 'filed' then
    if valor_cents is null or sentido is null then
      raise exception 'Indique o valor apurado e se e a reembolsar ou a pagar.';
    end if;
    if sentido not in ('refund','payment') or valor_cents < 0 then
      raise exception 'Valor apurado invalido.';
    end if;
    update public.irs_cases
       set status = destino, final_amount_cents = valor_cents, final_direction = sentido
     where id = processo;
  else
    update public.irs_cases set status = destino where id = processo;
  end if;

  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (conta, processo, auth.uid(),
            coalesce(rotulos->>destino, destino),
            coalesce(nullif(trim(nota), ''), corpos->>destino, destino));

  return destino;
end $$;

-- A mesma tabela passa a valer para a via antiga, que aceitava qualquer salto.
create or replace function public.publish_case_progress(
  account uuid, process uuid, event_title text, event_body text, new_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare actual text;
begin
  if not public.is_staff() then raise exception 'Not authorized' using errcode='42501'; end if;
  select status into actual from public.irs_cases where id = process and account_id = account;
  if actual is null then raise exception 'Process not found'; end if;
  if new_status is distinct from actual
     and not (new_status = any(public.transicoes_do_estado(actual))) then
    raise exception 'De "%" nao se pode passar a "%".', actual, new_status;
  end if;
  update public.irs_cases set status = new_status where id = process and account_id = account;
  insert into public.progress_events(account_id, case_id, author_id, title, body)
    values (account, process, auth.uid(), event_title, event_body);
end $$;

commit;
