import { notFound } from 'next/navigation';
import { session } from '@/lib/auth';
import { carregarGabinete } from '@/lib/irs-actions';
import { ROTULOS } from '@/lib/fluxo';
import { uuid } from '@/lib/data';
import { SEPARADORES, DEDUCOES, pertence } from '@/components/irs/separadores';
import r from './relatorio.module.css';

export const metadata = { title: 'Relatório do processo' };
export const dynamic = 'force-dynamic';

type Props = { params: Promise<{ processo: string }> };

const euros = (c: number | null) =>
  c == null ? '—' : (c / 100).toLocaleString('pt-PT', { style: 'currency', currency: 'EUR' });
const dia = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-PT') : '—');

/* Um resumo do processo numa página só, feito para ser impresso ou guardado
   em PDF pelo próprio browser. Não traz dependências novas e sai sempre com
   os tipos de letra certos, que é mais do que um PDF gerado à mão daria. */
export default async function Relatorio({ params }: Props) {
  await session();
  const { processo } = await params;
  if (!uuid(processo)) notFound();

  const { dados } = await carregarGabinete('processo', processo);
  if (!dados || dados.erro) notFound();

  const cab = (dados.cabecalho as Record<string, string>) || {};
  const membros = (dados.membros as Record<string, never>[]) || [];
  const rendimentos = (dados.rendimentos as Record<string, never>[]) || [];
  const documentos = (dados.documentos as Record<string, never>[]) || [];
  const imoveis = (dados.imoveis as { id: string; nome: string }[]) || [];
  const notas = (dados.notas as Record<string, string>) || {};

  const nome = (id: string) =>
    (membros.find((m) => String(m.id) === id) as { nome?: string } | undefined)?.nome || '—';
  const imovel = (id: string) => imoveis.find((i) => i.id === id)?.nome || '—';

  return (
    <main className={r.folha}>
      <header className={r.topo}>
        <img src="/rr.svg" alt="RR." width={259} height={142} className={r.logo} />
        <div>
          <h1>Resumo do processo de IRS {cab.ano}</h1>
          <p>
            {cab.cliente}
            {cab.nif ? ` · NIF ${cab.nif}` : ''}
            {cab.residencia ? ` · residência ${cab.residencia}` : ''}
          </p>
          <p>
            Estado: {ROTULOS[cab.estado] || cab.estado} · desde {dia(cab.desde)} ·
            {' '}emitido a {new Date().toLocaleString('pt-PT')}
          </p>
        </div>
      </header>

      <section>
        <h2>Agregado familiar</h2>
        <table className={r.tabela}>
          <thead><tr><th>Nome</th><th>NIF</th><th>Nascimento</th><th>Relação</th><th>Senha AT</th></tr></thead>
          <tbody>
            {membros.map((m) => (
              <tr key={String(m.id)}>
                <td>{String(m.nome)}</td>
                <td>{String(m.nif || '—')}</td>
                <td>{dia(m.nascimento as unknown as string)}</td>
                <td>{String(m.relacao)}</td>
                <td>{m.tem_senha ? 'Guardada' : 'Em falta'}{m.dois_fatores ? ' · 2FA' : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {[...SEPARADORES, { id: DEDUCOES.id, categoria: 'deduction', titulo: DEDUCOES.titulo }].map((s) => {
        // Capitais e mais-valias de ações partilham categoria: o pertence() separa-os.
        const meus = s.id === DEDUCOES.id ? [] : rendimentos.filter((x) =>
          pertence({ categoria: String(x.categoria), venda_em: (x as { venda_em?: string | null }).venda_em ?? null }, s));
        const docs = documentos.filter((d) => String(d.categoria) === s.categoria);
        if (meus.length === 0 && docs.length === 0 && !notas[s.categoria]) return null;
        return (
          <section key={s.id}>
            <h2>{s.titulo}</h2>
            {meus.length > 0 && (
              <table className={r.tabela}>
                <thead><tr><th>Titular</th><th>Tipo</th><th>Valor</th><th>Compra → venda</th></tr></thead>
                <tbody>
                  {meus.map((x) => (
                    <tr key={String(x.id)}>
                      <td>
                        {nome(String(x.titular))}
                        {x.imovel ? ` · ${imovel(String(x.imovel))}` : ''}
                      </td>
                      <td>
                        {String(x.tipo || x.ambito || '—')}
                        {x.irs_jovem ? ' · IRS Jovem' : ''}
                        {x.hpp ? ' · reinvestimento HPP' : ''}
                      </td>
                      <td>{euros(x.valor as unknown as number)}</td>
                      <td>
                        {x.venda_em
                          ? `${euros(x.compra as unknown as number)} → ${euros(x.venda as unknown as number)} (${dia(x.venda_em as unknown as string)})`
                          : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            {docs.length > 0 && (
              <p className={r.docs}>
                Documentos: {docs.map((d) => String(d.descricao || d.tipo)).join(' · ')}
              </p>
            )}
            {notas[s.categoria] && <p className={r.nota}>Nota do cliente: {notas[s.categoria]}</p>}
          </section>
        );
      })}

      <footer className={r.rodape}>
        Rúben Miguel da Silva Duarte Meirinho Rodrigues · Contabilista Certificado n.º 145854
        <br />
        Documento de apoio interno. Não substitui a declaração submetida na Autoridade Tributária.
      </footer>
    </main>
  );
}
