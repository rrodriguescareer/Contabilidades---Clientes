import { NextResponse, type NextRequest } from 'next/server';
import { adminClient } from '@/lib/admin-client';
import { enviarPedido, enviarResumoSemanal } from '@/lib/secretaria-envio';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

/* O relógio da Secretária. A base de dados chama isto de hora a hora, com uma
   chave que só ela conhece (guarda-se o hash). Não recebe dados: faz apenas o
   que já estava marcado. */
export async function POST(request: NextRequest) {
  const admin = adminClient();
  const chave = request.headers.get('x-secretaria-chave') || '';
  const { data: valida } = chave ? await admin.rpc('secretaria_chave_valida', { p_chave: chave }) : { data: false };
  if (!valida) return NextResponse.json({ erro: 'Sem acesso.' }, { status: 401 });

  const { data, error } = await admin.rpc('secretaria_tarefas');
  if (error) {
    console.error(JSON.stringify({ event: 'rr_secretaria_tarefas', erro: error.message }));
    return NextResponse.json({ erro: 'Tarefas indisponíveis.' }, { status: 500 });
  }
  const tarefas = data as { a_enviar: string[]; criados: number; terminados: number };
  let enviados = 0;
  for (const id of tarefas.a_enviar) {
    if ((await enviarPedido(id)).ok) enviados++;
  }

  // À segunda, às oito de Lisboa.
  const partes = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon', weekday: 'short', hour: '2-digit', hour12: false, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const parte = (t: string) => partes.find((p) => p.type === t)?.value || '';
  const resumo = parte('weekday') === 'Mon' && Number(parte('hour')) === 8
    ? await enviarResumoSemanal(`${parte('year')}-${parte('month')}-${parte('day')}`)
    : false;

  return NextResponse.json({ criados: tarefas.criados, terminados: tarefas.terminados, enviados, resumo });
}
