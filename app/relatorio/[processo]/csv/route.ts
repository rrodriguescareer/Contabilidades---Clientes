import { NextResponse } from 'next/server';
import { uuid } from '@/lib/data';
import { dataHora, lerRelatorio } from '@/lib/relatorio-atividade';

export const dynamic = 'force-dynamic';

/* O registo cronológico em CSV, para abrir no Excel. Separador ";" e BOM
   UTF-8, que é o que o Excel português espera para acentos e colunas. */
export async function GET(_pedido: Request, { params }: { params: Promise<{ processo: string }> }) {
  const { processo } = await params;
  if (!uuid(processo)) return NextResponse.json({ erro: 'Processo inválido.' }, { status: 400 });
  const dados = await lerRelatorio(processo);
  if (!dados) return NextResponse.json({ erro: 'Sem acesso.' }, { status: 404 });

  const celula = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""').replace(/\r?\n/g, ' ')}"`;
  const linhas = [
    ['N.º', 'Data e hora (Lisboa)', 'Origem', 'Evento', 'Detalhe'],
    ...dados.eventos.map((e, i) => [i + 1, dataHora(e.em), e.origem, e.evento, e.detalhe || '']),
  ];
  const corpo = '﻿' + linhas.map((l) => l.map(celula).join(';')).join('\r\n');
  const nome = `relatorio-atividade-${processo.slice(0, 8)}.csv`;
  return new NextResponse(corpo, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${nome}"`,
      'Cache-Control': 'private, no-store',
    },
  });
}
