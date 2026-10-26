import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { activarPolitica, alternarCampanha, guardarCampanha, guardarPolitica } from '@/lib/precos-actions';
import { data as formatarData } from '@/lib/apresentar';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Preços e campanhas' };

const EUROS = new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' });
const euros = (c: number) => EUROS.format((c || 0) / 100);

/* Os mesmos nomes que a função de preço usa, com a explicação do que cada um
   faz — sem isso, daqui a um ano ninguém sabe o que é "b_adicional". */
const CAMPOS: { id: string; rotulo: string; nota: string }[] = [
  { id: 'base', rotulo: 'Base', nota: 'Primeiro tipo de rendimento. Está sempre.' },
  { id: 'varios_titulares', rotulo: 'Vários titulares', nota: 'Mais do que uma pessoa com trabalho ou pensões.' },
  { id: 'a_e_b', rotulo: 'Categorias A e B', nota: 'Trabalho dependente acumulado com independente.' },
  { id: 'b_adicional', rotulo: 'B sobre pensões', nota: 'Independente acumulado com pensões.' },
  { id: 'rendas_unica', rotulo: 'Rendas — único rendimento', nota: 'Até 2 imóveis, sem mais nada declarado.' },
  { id: 'rendas_ate2', rotulo: 'Rendas — até 2 imóveis', nota: 'Com outros rendimentos.' },
  { id: 'rendas_ate5', rotulo: 'Rendas — 3 a 5 imóveis', nota: '' },
  { id: 'rendas_mais', rotulo: 'Rendas — 6 ou mais', nota: '' },
  { id: 'mais_valias_titulos', rotulo: 'Mais-valias de títulos', nota: 'Ações e outros, categoria G.' },
  { id: 'mais_valias_imovel', rotulo: 'Mais-valias por imóvel', nota: 'Multiplicado pelo número de imóveis vendidos.' },
];

type Politica = { id: string; nome: string; activa: boolean; valores: Record<string, number>; notas: string; criada_em: string };
type Campanha = { id: string; nome: string; rotulo_publico: string; tipo: string; valor: number; activa: boolean; inicio: string | null; fim: string | null };

export default async function Precos({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const [{ data: politicas }, { data: campanhas }, { data: vigor }] = await Promise.all([
    client.from('pricing_policies').select('*').order('criada_em', { ascending: false }),
    client.from('campaigns').select('*').order('criada_em', { ascending: false }),
    client.rpc('precos_em_vigor'),
  ]);

  const emVigor = (vigor || {}) as Record<string, number>;
  const activa = (politicas as Politica[] | null)?.find((p) => p.activa);

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <Secao
        titulo="Preços em vigor"
        nota={activa ? `Política «${activa.nome}».` : 'Sem política criada — valem os valores de origem.'}
      >
        <div className="cartao">
          <table className="tabela">
            <tbody>
              {CAMPOS.map((c) => (
                <tr key={c.id}>
                  <td>
                    <strong>{c.rotulo}</strong>
                    {c.nota && <><br /><span className="tenue micro">{c.nota}</span></>}
                  </td>
                  <td style={{ textAlign: 'right' }}>{euros(emVigor[c.id])}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Secao>

      <Secao titulo="Nova política" nota="Os preços são por rendimento declarado, com IVA incluído. Guardar não ativa: ativa-se à parte, para poder preparar a campanha seguinte com antecedência.">
        <form action={guardarPolitica} className="cartao pilha pilha-4">
          <label className="campo">
            <span>Nome</span>
            <input name="nome" className="entrada" required maxLength={120} placeholder="IRS 2026 — tabela base" />
          </label>

          <div className="grelha grelha-auto">
            {CAMPOS.map((c) => (
              <label className="campo" key={c.id}>
                <span>{c.rotulo}</span>
                <input name={c.id} type="number" className="entrada" min="0" step="0.01"
                       defaultValue={((emVigor[c.id] || 0) / 100).toFixed(2)} required />
                {c.nota && <span className="tenue micro">{c.nota}</span>}
              </label>
            ))}
          </div>

          <label className="campo">
            <span>Notas internas</span>
            <textarea name="notas" className="entrada" rows={2} maxLength={500} />
          </label>

          <label className="caixa">
            <input type="checkbox" name="activar" />
            <span className="pequeno">Pôr em vigor imediatamente</span>
          </label>

          <Submeter>Guardar política</Submeter>
        </form>
      </Secao>

      <Secao titulo="Histórico de políticas" nota="A que está em vigor manda no preço de todos os orçamentos novos.">
        <div className="cartao">
          {(politicas as Politica[] | null)?.length ? (
            <table className="tabela">
              <thead>
                <tr><th>Nome</th><th>Base</th><th>Criada</th><th>Estado</th><th /></tr>
              </thead>
              <tbody>
                {(politicas as Politica[]).map((p) => (
                  <tr key={p.id}>
                    <td><strong>{p.nome}</strong>{p.notas && <><br /><span className="tenue micro">{p.notas}</span></>}</td>
                    <td>{euros(p.valores?.base)}</td>
                    <td>{formatarData(p.criada_em)}</td>
                    <td>{p.activa ? <span className="etiqueta etiqueta-positivo">Em vigor</span> : <span className="etiqueta">Arquivada</span>}</td>
                    <td>
                      {!p.activa && (
                        <form action={activarPolitica}>
                          <input type="hidden" name="id" value={p.id} />
                          <Submeter className="btn btn-secundario">Pôr em vigor</Submeter>
                        </form>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="tenue">Ainda não criou nenhuma política.</p>
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
