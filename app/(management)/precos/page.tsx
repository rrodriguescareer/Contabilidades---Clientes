import Link from 'next/link';
import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { alternarCampanha, ativarPoliticaPrecos, guardarCampanha } from '@/lib/precos-actions';
import { quando, quanto, type Regra } from '@/lib/precos-regras';
import { data as formatarData } from '@/lib/apresentar';
import { EditorPrecos } from './editor';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Preços e campanhas' };

const EUROS = new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' });
const euros = (c: number) => EUROS.format((c || 0) / 100);

type Politica = {
  id: string; nome: string; activa: boolean; valores: Record<string, number>; regras: Regra[] | null; notas: string | null;
  minimo_cents: number | null; maximo_cents: number | null; origem: string | null; criada_em: string;
};
type Periodo = { policy_id: string; ativada_em: string; desativada_em: string | null };
type Campanha = { id: string; nome: string; rotulo_publico: string; tipo: string; valor: number; activa: boolean; inicio: string | null; fim: string | null };

/** As regras de uma política, numa tabela que se lê: o que custa e quando. */
function Regras({ regras, minimo, maximo }: { regras: Regra[]; minimo?: number | null; maximo?: number | null }) {
  const nome = (id: string) => regras.find((r) => r.id === id)?.rotulo ?? id;
  return (
    <table className="tabela">
      <thead><tr><th>Linha</th><th>Quando</th><th style={{ textAlign: 'right' }}>Valor</th></tr></thead>
      <tbody>
        {regras.map((r) => (
          <tr key={r.id} style={{ opacity: r.ativa === false ? 0.5 : 1 }}>
            <td><strong>{r.rotulo}</strong>{r.ativa === false && <span className="tenue micro"> · desligada</span>}
              {r.anula?.length ? <><br /><span className="tenue micro">Anula: {r.anula.map(nome).join(', ')}</span></> : null}</td>
            <td className="micro">{quando(r)}</td>
            <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>{quanto(r)}</td>
          </tr>
        ))}
        {(minimo != null || maximo != null) && (
          <tr><td colSpan={3} className="micro tenue">
            {minimo != null ? `Mínimo ${euros(minimo)}` : ''}{minimo != null && maximo != null ? ' · ' : ''}{maximo != null ? `Máximo ${euros(maximo)}` : ''}
          </td></tr>
        )}
      </tbody>
    </table>
  );
}

export default async function Precos({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string; base?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const [{ data: politicas }, { data: campanhas }, { data: vigor }, { data: historico }] = await Promise.all([
    client.from('pricing_policies').select('id,nome,activa,valores,regras,notas,minimo_cents,maximo_cents,origem,criada_em').order('criada_em', { ascending: false }),
    client.from('campaigns').select('*').order('criada_em', { ascending: false }),
    client.rpc('precos_em_vigor'),
    client.from('pricing_historico').select('policy_id,ativada_em,desativada_em').order('ativada_em', { ascending: false }),
  ]);
  const lista = (politicas ?? []) as Politica[];
  const periodos = (historico ?? []) as Periodo[];
  // As regras de uma política antiga (só com valores) são as de sempre.
  const { data: padrao } = await client.rpc('regras_padrao', { v: vigor || {} });
  const regrasDe = async (p: Politica | undefined) =>
    p?.regras ?? (p ? ((await client.rpc('regras_padrao', { v: p.valores || {} })).data as Regra[]) : (padrao as Regra[]));
  const activa = lista.find((p) => p.activa);
  const emVigor = await regrasDe(activa);
  // O editor começa na política pedida (?base=), ou na que está em vigor.
  const base = lista.find((p) => p.id === parametros.base) ?? activa;
  const regrasBase = await regrasDe(base);

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <Secao
        titulo="Preços em vigor"
        nota={activa ? `Política «${activa.nome}», em vigor desde ${formatarData(periodos.find((x) => x.policy_id === activa.id)?.ativada_em ?? activa.criada_em)}.` : 'Sem política criada: valem as regras de origem.'}
      >
        <div className="cartao"><Regras regras={emVigor} minimo={activa?.minimo_cents} maximo={activa?.maximo_cents} /></div>
      </Secao>

      <Secao
        titulo={base ? `Nova versão a partir de «${base.nome}»` : 'Nova versão a partir das regras de origem'}
        nota="Cada linha é uma regra: o valor, as condições em que se aplica (todas têm de se cumprir), se cobra por unidade e que outras linhas anula. Gravar cria uma versão nova; as anteriores ficam no histórico."
      >
        <div id="editor">
          <EditorPrecos key={base?.id ?? 'origem'} inicial={regrasBase} origem={base?.id ?? null}
                        nomeInicial={base ? `${base.nome} (revista)` : 'IRS — tabela base'} notasInicial=""
                        minimoInicial={base?.minimo_cents ?? null} maximoInicial={base?.maximo_cents ?? null} />
        </div>
      </Secao>

      <Secao titulo="Histórico de políticas" nota="Todas as versões ficam guardadas. Qualquer uma pode voltar a vigorar, ou servir de ponto de partida para outra.">
        <div className="cartao">
          {lista.length ? (
            <div className="pilha pilha-3">
              {lista.map((p) => {
                const vezes = periodos.filter((x) => x.policy_id === p.id);
                return (
                  <details key={p.id} className="pilha pilha-2">
                    <summary className="linha" style={{ cursor: 'pointer', flexWrap: 'wrap', gap: 'var(--e-3)' }}>
                      <strong>{p.nome}</strong>
                      {p.activa ? <span className="etiqueta etiqueta-positivo">Em vigor</span> : <span className="etiqueta">Arquivada</span>}
                      <span className="micro tenue">Criada a {formatarData(p.criada_em)}{p.origem ? ` · a partir de «${lista.find((x) => x.id === p.origem)?.nome ?? 'outra'}»` : ''}</span>
                    </summary>
                    {p.notas && <p className="micro tenue">{p.notas}</p>}
                    {vezes.length > 0 && (
                      <p className="micro">Em vigor: {vezes.map((x) => `${formatarData(x.ativada_em)} — ${x.desativada_em ? formatarData(x.desativada_em) : 'hoje'}`).join(' · ')}</p>
                    )}
                    <Regras regras={p.regras ?? (padrao as Regra[])} minimo={p.minimo_cents} maximo={p.maximo_cents} />
                    <div className="linha">
                      {!p.activa && (
                        <form action={ativarPoliticaPrecos}>
                          <input type="hidden" name="id" value={p.id} />
                          <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">Repor em vigor</Submeter>
                        </form>
                      )}
                      <Link className="btn btn-discreto btn-sm" href={`/precos?base=${p.id}#editor`}>Editar a partir desta</Link>
                    </div>
                  </details>
                );
              })}
            </div>
          ) : (
            <p className="tenue">Ainda não há versões gravadas. A primeira que gravar começa nas regras de origem.</p>
          )}
        </div>
      </Secao>

      <Secao titulo="Campanhas" nota="Um desconto aplicado a toda a gente durante um período. Os códigos de desconto continuam a funcionar à parte, para casos individuais.">
        <form action={guardarCampanha} className="cartao pilha pilha-4">
          <div className="grelha grelha-auto">
            <label className="campo">
              <span>Nome interno</span>
              <input name="nome" className="entrada" required maxLength={120} placeholder="Campanha de lançamento" />
            </label>
            <label className="campo">
              <span>Texto que o cliente vê</span>
              <input name="rotulo_publico" className="entrada" required maxLength={160} placeholder="Desconto de lançamento" />
            </label>
            <label className="campo">
              <span>Tipo</span>
              <select name="tipo" className="entrada">
                <option value="percentagem">Percentagem (%)</option>
                <option value="fixo">Valor fixo (€)</option>
              </select>
            </label>
            <label className="campo">
              <span>Valor</span>
              <input name="valor" type="number" className="entrada" min="0.01" step="0.01" required />
            </label>
            <label className="campo">
              <span>Início (opcional)</span>
              <input name="inicio" type="datetime-local" className="entrada" />
            </label>
            <label className="campo">
              <span>Fim (opcional)</span>
              <input name="fim" type="datetime-local" className="entrada" />
            </label>
          </div>
          <label className="caixa">
            <input type="checkbox" name="activar" />
            <span className="pequeno">Ligar assim que guardar</span>
          </label>
          <Submeter>Guardar campanha</Submeter>
        </form>

        <div className="cartao">
          {(campanhas as Campanha[] | null)?.length ? (
            <table className="tabela">
              <thead><tr><th>Campanha</th><th>Desconto</th><th>Janela</th><th>Estado</th><th /></tr></thead>
              <tbody>
                {(campanhas as Campanha[]).map((c) => (
                  <tr key={c.id}>
                    <td><strong>{c.nome}</strong><br /><span className="tenue micro">{c.rotulo_publico}</span></td>
                    <td>{c.tipo === 'percentagem' ? `${c.valor}%` : euros(c.valor)}</td>
                    <td className="micro tenue">
                      {c.inicio ? formatarData(c.inicio) : 'sempre'} — {c.fim ? formatarData(c.fim) : 'sem fim'}
                    </td>
                    <td>{c.activa ? <span className="etiqueta etiqueta-positivo">Ligada</span> : <span className="etiqueta">Desligada</span>}</td>
                    <td>
                      <form action={alternarCampanha}>
                        <input type="hidden" name="id" value={c.id} />
                        <input type="hidden" name="activa" value={String(c.activa)} />
                        <Submeter className="btn btn-secundario">{c.activa ? 'Desligar' : 'Ligar'}</Submeter>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="tenue">Sem campanhas.</p>
          )}
        </div>
      </Secao>
    </>
  );
}
