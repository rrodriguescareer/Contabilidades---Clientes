import { ownerSession as session } from '@/lib/auth';
import { Avisos as Mensagens, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { alternarAviso, apagarAviso, guardarAviso } from '@/lib/precos-actions';
import { data as formatarData } from '@/lib/apresentar';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Avisos' };

type Aviso = {
  id: string; mensagem: string; tom: string; activo: boolean;
  inicio: string | null; fim: string | null; no_irs: boolean; no_website: boolean;
};

const TOM: Record<string, string> = { info: 'Informação', atencao: 'Atenção', critico: 'Crítico' };

export default async function Pagina({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;
  const { data: avisos } = await client.from('avisos').select('*').order('criado_em', { ascending: false });

  return (
    <>
      <Mensagens erro={parametros.erro} mensagem={parametros.mensagem} />

      <Secao
        titulo="Novo aviso"
        nota="Aparece no topo da plataforma de IRS e, se quiser, no website. Serve para dizer o que está a acontecer antes de alguém perguntar."
      >
        <form action={guardarAviso} className="cartao pilha pilha-4">
          <label className="campo">
            <span>Mensagem</span>
            <textarea name="mensagem" className="entrada" rows={2} required minLength={5} maxLength={400}
                      placeholder="Por motivos de ordem técnica, podem ocorrer dificuldades pontuais no processo de login." />
          </label>

          <div className="grelha grelha-auto">
            <label className="campo">
              <span>Tom</span>
              <select name="tom" className="entrada">
                <option value="info">Informação</option>
                <option value="atencao">Atenção</option>
                <option value="critico">Crítico</option>
              </select>
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
            <input type="checkbox" name="no_irs" defaultChecked />
            <span className="pequeno">Mostrar na plataforma de IRS</span>
          </label>
          <label className="caixa">
            <input type="checkbox" name="no_website" />
            <span className="pequeno">Mostrar também no website</span>
          </label>
          <label className="caixa">
            <input type="checkbox" name="activar" />
            <span className="pequeno">Pôr no ar assim que guardar</span>
          </label>

          <Submeter>Guardar aviso</Submeter>
        </form>
      </Secao>

      <Secao titulo="Avisos" nota="Um aviso no ar fora da janela de datas não aparece: a janela manda.">
        <div className="cartao">
          {(avisos as Aviso[] | null)?.length ? (
            <table className="tabela">
              <thead><tr><th>Mensagem</th><th>Tom</th><th>Onde</th><th>Janela</th><th>Estado</th><th /></tr></thead>
              <tbody>
                {(avisos as Aviso[]).map((a) => (
                  <tr key={a.id}>
                    <td>{a.mensagem}</td>
                    <td>{TOM[a.tom] || a.tom}</td>
                    <td className="micro tenue">
                      {[a.no_irs && 'IRS', a.no_website && 'Website'].filter(Boolean).join(' · ') || '—'}
                    </td>
                    <td className="micro tenue">
                      {a.inicio ? formatarData(a.inicio) : 'sempre'} — {a.fim ? formatarData(a.fim) : 'sem fim'}
                    </td>
                    <td>
                      {a.activo
                        ? <span className="etiqueta etiqueta-positivo">No ar</span>
                        : <span className="etiqueta">Desligado</span>}
                    </td>
                    <td>
                      <div className="pilha pilha-2">
                        <form action={alternarAviso}>
                          <input type="hidden" name="id" value={a.id} />
                          <input type="hidden" name="activo" value={String(a.activo)} />
                          <Submeter className="btn btn-secundario">{a.activo ? 'Desligar' : 'Pôr no ar'}</Submeter>
                        </form>
                        <form action={apagarAviso}>
                          <input type="hidden" name="id" value={a.id} />
                          <Submeter className="btn btn-texto">Apagar</Submeter>
                        </form>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="tenue">Sem avisos.</p>
          )}
        </div>
      </Secao>
    </>
  );
}
