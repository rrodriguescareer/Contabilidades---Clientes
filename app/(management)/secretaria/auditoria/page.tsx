import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { dataHoraPt } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Auditoria · Secretária' };

const POR_PAGINA = 50;

export default async function Auditoria({ searchParams }: { searchParams: Promise<{ q?: string; pagina?: string }> }) {
  const { client } = await ownerSession();
  const pedido = await searchParams;
  const pagina = Math.max(1, Number(pedido.pagina) || 1);
  const q = (pedido.q || '').trim().replace(/["\\%]/g, '').slice(0, 60);
  let consulta = client.from('secretaria_auditoria').select('seq,quando,acao,autor,empresa,detalhe').order('seq', { ascending: false }).range((pagina - 1) * POR_PAGINA, pagina * POR_PAGINA);
  if (q) consulta = consulta.or(`acao.ilike."%${q}%",empresa.ilike."%${q}%",autor.ilike."%${q}%",detalhe.ilike."%${q}%"`);
  const [{ data }, { data: v }] = await Promise.all([consulta, client.rpc('secretaria_auditoria_verificar')]);
  const linhas = (data ?? []).slice(0, POR_PAGINA);
  const haMais = (data ?? []).length > POR_PAGINA;
  const verificacao = v as { valida: boolean; eventos: number; quebra?: number } | null;
  const url = (n: number) => `/secretaria/auditoria?${new URLSearchParams({ ...(pedido.q ? { q: pedido.q } : {}), pagina: String(n) }).toString()}`;

  return (
    <div className={s.pagina}>
      <div className={s.barraFerramentas}>
        <p className="suave">Cada ação fica registada e encadeada na anterior: alterar o passado parte a cadeia.</p>
        {verificacao && (
          <span className={s.selo} data-ok={verificacao.valida ? 'true' : 'false'}>
            {verificacao.valida ? `✓ ${verificacao.eventos} eventos verificados` : `A cadeia quebra no evento ${verificacao.quebra}`}
          </span>
        )}
      </div>
      <form className={s.procura} action="/secretaria/auditoria">
        <input type="search" name="q" className="entrada" placeholder="Procurar ação, cliente ou autor…" aria-label="Procurar" defaultValue={pedido.q} />
      </form>
      {linhas.length === 0 ? (
        <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Sem registos</strong><span>Quando houver atividade, aparece aqui.</span></div>
      ) : (
        <div className={s.envolve}>
          <table className={s.tabela}>
            <thead><tr><th>Quando</th><th>Ação</th><th>Autor</th><th>Entidade</th><th>Detalhe</th></tr></thead>
            <tbody>
              {linhas.map((l) => (
                <tr key={l.seq}>
                  <td data-rotulo="Quando" className={s.nowrap}>{dataHoraPt(l.quando)}</td>
                  <td data-rotulo="Ação"><strong>{l.acao}</strong></td>
                  <td data-rotulo="Autor" className={s.detalhe}>{l.autor}</td>
                  <td data-rotulo="Entidade">{l.empresa ?? 'Gabinete'}</td>
                  <td data-rotulo="Detalhe" className={s.detalhe}>{l.detalhe ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {(pagina > 1 || haMais) && (
        <div className={s.acoes}>
          {pagina > 1 && <Link prefetch={false} className="btn btn-secundario btn-sm" href={url(pagina - 1)}>Mais recentes</Link>}
          {haMais && <Link prefetch={false} className="btn btn-secundario btn-sm" href={url(pagina + 1)}>Mais antigos</Link>}
        </div>
      )}
    </div>
  );
}
