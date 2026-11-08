import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { arquivarDocumento, marcarRevisto } from '@/lib/secretaria-actions';
import { dataHoraPt, linhaDocumento, type PendenciaAberta } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Por identificar · Secretária' };

type Registo = { id: string; company_id: string; criado_em: string; documento: { id: string; nome: string; mes: string } | null; empresa: { name: string } | null };

/* O número do documento no nome do ficheiro, para sugerir a pendência certa. */
const sugestao = (nome: string, lista: PendenciaAberta[]) => {
  const limpo = nome.toLowerCase().replace(/[^a-z0-9]/g, '');
  return lista.find((p) => p.numero && p.numero.replace(/[^a-zA-Z0-9]/g, '').length >= 3 && limpo.includes(p.numero.toLowerCase().replace(/[^a-z0-9]/g, '')))?.id;
};

export default async function PorIdentificar({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const avisos = await searchParams;
  const { data } = await client.from('secretaria_por_identificar')
    .select('id,company_id,criado_em,documento:empresa_documentos(id,nome,mes),empresa:companies(name)')
    .eq('estado', 'por_rever').order('criado_em', { ascending: false }).limit(100);
  const registos = (data ?? []) as unknown as Registo[];
  const empresas = [...new Set(registos.map((r) => r.company_id))];
  const { data: abertas } = empresas.length
    ? await client.from('secretaria_pendencias').select('id,company_id,periodo,tipo,descricao,numero,data_documento,valor_cents,banco').in('company_id', empresas).eq('estado', 'pendente').order('data_documento', { nullsFirst: false }).limit(1000)
    : { data: [] as (PendenciaAberta & { company_id: string })[] };
  const daEmpresa = (id: string) => ((abertas ?? []) as (PendenciaAberta & { company_id: string })[]).filter((p) => p.company_id === id);

  return (
    <div className={s.pagina}>
      <Avisos erro={avisos.erro} mensagem={avisos.mensagem} />
      <div className={s.intro}><p>Documentos que chegaram sem corresponder a uma pendência. Diga a que pedido pertencem, ou arquive-os.</p></div>

      {registos.length === 0 ? (
        <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Nada por identificar</strong><span>Tudo o que chegou já está associado.</span></div>
      ) : (
        <div className={s.envolve}>
          <table className={s.tabela}>
            <thead><tr><th>Documento</th><th>Cliente</th><th>Recebido</th><th>Pendência</th></tr></thead>
            <tbody>
              {registos.map((r) => {
                const opcoes = daEmpresa(r.company_id);
                const sugerida = sugestao(r.documento?.nome ?? '', opcoes);
                return (
                  <tr key={r.id}>
                    <td data-rotulo="">
                      <strong className={s.detalhe}>{r.documento?.nome}</strong>
                      {r.documento && <a className={`${s.segundo}`} href={`/secretaria/documento/${r.documento.id}`} target="_blank" rel="noreferrer">Abrir documento</a>}
                    </td>
                    <td data-rotulo="Cliente"><Link prefetch={false} className={s.nome} href={`/secretaria/clientes/${r.company_id}`}>{r.empresa?.name}</Link></td>
                    <td data-rotulo="Recebido" className={s.nowrap}>{dataHoraPt(r.criado_em)}</td>
                    <td data-rotulo="">
                      <form action={arquivarDocumento} className={s.filtrosTabela}>
                        <input type="hidden" name="registo" value={r.id} /><input type="hidden" name="voltar" value="/secretaria/identificar" />
                        <select name="pendencia" className="entrada" aria-label="Pendência" defaultValue={sugerida ?? ''} required style={{ flex: '1 1 14rem', inlineSize: 'auto', maxInlineSize: '26rem' }}>
                          <option value="" disabled>Escolher…</option>
                          {opcoes.map((p) => <option key={p.id} value={p.id}>{p.id === sugerida ? '★ ' : ''}{linhaDocumento(p)}</option>)}
                          <option value="nenhuma">Nenhuma: não foi usado</option>
                        </select>
                        <Submeter className={s.acaoPequena} aDecorrer="…">Arquivar</Submeter>
                      </form>
                      <form action={marcarRevisto} style={{ marginBlockStart: '.35rem' }}>
                        <input type="hidden" name="registo" value={r.id} /><input type="hidden" name="voltar" value="/secretaria/identificar" />
                        <button className="btn-texto pequeno" type="submit">Marcar como revisto</button>
                      </form>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
