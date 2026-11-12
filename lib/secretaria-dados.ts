import 'server-only';
import type { SupabaseClient } from '@supabase/supabase-js';
import { hojeLisboa, limiteDoPeriodo, type ClienteResumo, type Periodo } from './secretaria';

/* O resumo de entrega por cliente.
 *
 * Num mês ou num trimestre, o prazo conta-se a partir desse período. Em «Todos
 * os períodos» não há período de referência: um cliente sem processo em curso
 * aparecia sempre «Em dia», mesmo com documentos de há meses por entregar.
 * Aqui o prazo passa a contar a partir do documento em falta mais antigo. */
export async function clientesResumo(client: SupabaseClient, periodo: Pick<Periodo, 'modo' | 'desde' | 'ate'>): Promise<ClienteResumo[]> {
  const { data } = await client.rpc('secretaria_clientes_resumo', { desde: periodo.desde, ate: periodo.ate });
  const lista = (data ?? []) as ClienteResumo[];
  if (periodo.modo !== 'todos' || !lista.some((c) => !c.processo && c.em_falta > 0)) return lista;

  const [{ data: abertas }, { data: proprios }, { data: geral }] = await Promise.all([
    client.from('secretaria_pendencias').select('company_id,periodo').eq('estado', 'pendente').order('periodo').limit(5000),
    client.from('secretaria_clientes').select('company_id,dia_limite'),
    client.from('secretaria_definicoes').select('dia_limite').maybeSingle(),
  ]);
  const maisAntigo = new Map<string, string>();
  for (const p of abertas ?? []) if (!maisAntigo.has(p.company_id)) maisAntigo.set(p.company_id, String(p.periodo));
  const diaProprio = new Map((proprios ?? []).map((x) => [x.company_id as string, x.dia_limite as number | null]));
  const hoje = hojeLisboa();

  return lista.map((c) => {
    const desde = maisAntigo.get(c.id);
    if (c.processo || !c.em_falta || !desde) return c;
    const limite = limiteDoPeriodo(desde, diaProprio.get(c.id) ?? geral?.dia_limite ?? 10);
    const dias = Math.round((Date.parse(limite) - Date.parse(hoje)) / 86_400_000);
    return { ...c, limite, prazo: dias < 0 ? 'fora' : dias >= 14 ? 'em_dia' : dias >= 7 ? 'apertado' : 'em_risco' };
  });
}

export const TODOS: Pick<Periodo, 'modo' | 'desde' | 'ate'> = { modo: 'todos', desde: '2000-01-01', ate: '2099-12-01' };
