'use client';
import { useCallback, useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { resolverAlertaDoGabinete } from '@/lib/irs-actions';
import { FASES, emRecolha, estadoDe, posicao } from '@/lib/fluxo';
import { Pilula } from './pilula';
import { Processo } from './processo';
import { Integracoes } from './integracoes';
import { ALERTAS, PAGAMENTOS } from './estados';
import e from './gabinete.module.css';

type Dados = Record<string, unknown> & { vista: string };
type Linha = Record<string, unknown>;

/* O gabinete do IRS, dentro da gestão. O endereço é que manda: a vista, o
   processo aberto e o separador estão todos no URL, e o servidor traz os
   dados de cada um num pedido só. Assim o "voltar" do browser funciona, uma
   ligação para um processo abre esse processo, e o menu lateral da gestão
   leva a qualquer vista sem estado escondido. */

const TITULOS: Record<string, string> = {
  fila: 'Processos', mensagens: 'Mensagens', pagamentos: 'Pagamentos',
  alertas: 'Alertas', integracoes: 'Integração Cegid',
};

const FILTROS = [
  { id: 'todos', rotulo: 'Todos' },
  { id: 'meus', rotulo: 'À minha espera' },
  ...FASES.map((f) => ({ id: f.id, rotulo: f.titulo })),
] as const;

const dia = (iso: unknown) => (iso ? new Date(String(iso)).toLocaleDateString('pt-PT') : '—');
const euros = (c: unknown) =>
  c == null ? '—' : (Number(c) / 100).toLocaleString('pt-PT', { style: 'currency', currency: 'EUR' });
const iniciais = (nome: string) =>
  nome.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]?.toUpperCase()).join('');

export function ConsolaIrs({ vista, dados, processo, aba, cegidConfigurado, cegidOrigem }: {
  vista: string; dados: Dados | null;
  processo: { id: string; dados: Dados } | null; aba?: string;
  cegidConfigurado: boolean; cegidOrigem: 'ambiente' | 'gabinete' | 'nenhuma';
}) {
  const router = useRouter();
  const [aCarregar, comecar] = useTransition();

  const ir = useCallback((url: string) => comecar(() => router.push(url)), [router]);
  const abrir = useCallback((id: string, separador?: string) =>
    ir(`/irs?processo=${id}${separador ? `&aba=${separador}` : ''}`), [ir]);
  // Estável de propósito: os filhos usam-no em efeitos.
  const recarregar = useCallback(() => comecar(() => router.refresh()), [router]);

  const totais = (dados?.totais as Record<string, number>) || {};
  const titulo = processo
    ? String((processo.dados.cabecalho as Linha | undefined)?.cliente || 'Processo')
    : TITULOS[vista] || 'Processos';

  return (
    <>
      <header className={e.topo}>
        {processo && (
          <button type="button" className={e.voltar}
                  onClick={() => (window.history.length > 1 ? router.back() : ir('/irs'))}>
            ← Voltar
          </button>
        )}
        <h1 className={e.titulo}>{titulo}</h1>
        <span className={e.ano}>IRS 2026</span>
        {aCarregar && <span className={e.carregar} aria-live="polite">A carregar…</span>}
      </header>

      <main id="principal" className={e.conteudo} data-ocupado={aCarregar}>
        {processo ? (
          <Processo key={processo.id} dados={processo.dados} processo={processo.id}
                    abaInicial={aba} aoMudar={recarregar} />
        ) : !dados ? (
          <p className="aviso-critico">Não foi possível carregar. Atualize a página.</p>
        ) : (
          <>
            {vista === 'fila' && <Fila dados={dados} totais={totais} abrir={abrir} />}
            {vista === 'mensagens' && <Conversas dados={dados} abrir={abrir} />}
            {vista === 'pagamentos' && <Pagamentos dados={dados} abrir={abrir} />}
            {vista === 'alertas' && <Alertas dados={dados} abrir={abrir} />}
            {vista === 'integracoes' && <Integracoes configurado={cegidConfigurado} origem={cegidOrigem} />}
          </>
        )}
      </main>
    </>
  );
}

/* ------------------------------------------------------------- processos */

function Fila({ dados, totais, abrir }:
  { dados: Dados; totais: Record<string, number>; abrir: (p: string, aba?: string) => void }) {
  const processos = (dados.processos as Linha[]) || [];
  const [filtro, setFiltro] = useState<string>('todos');
  const [procura, setProcura] = useState('');

  const visiveis = useMemo(() => {
    const q = procura.trim().toLowerCase();
    return processos.filter((p) => {
      const est = estadoDe(String(p.estado));
      if (filtro === 'meus' && est?.espera !== 'gabinete') return false;
      if (filtro !== 'todos' && filtro !== 'meus' && est?.fase !== filtro) return false;
      if (!q) return true;
      return [p.cliente, p.nif, p.email, p.telefone].some((v) => String(v || '').toLowerCase().includes(q));
    });
  }, [processos, filtro, procura]);

  return (
    <>
      <div className={e.indicadores}>
        <Indicador valor={totais.a_rever ?? 0} rotulo="À minha espera" destaque />
        <Indicador valor={totais.recolha ?? 0} rotulo="Em recolha pelo cliente" />
        <Indicador valor={totais.entregues ?? 0} rotulo="Entregues na AT" />
        <Indicador valor={totais.por_responder ?? 0} rotulo="Mensagens por responder" />
      </div>

      <section className={e.cartao}>
        <div className={e.barraFiltros}>
          <div className={e.filtros} role="tablist" aria-label="Filtrar por fase">
            {FILTROS.map((f) => (
              <button key={f.id} type="button" role="tab" aria-selected={filtro === f.id}
                      className={e.filtro} onClick={() => setFiltro(f.id)}>
                {f.rotulo}
              </button>
            ))}
          </div>
          <input className={`entrada ${e.procura}`} type="search" value={procura}
                 onChange={(ev) => setProcura(ev.target.value)}
                 placeholder="Procurar por nome, NIF, email ou telefone" aria-label="Procurar processos" />
        </div>

        {visiveis.length === 0 ? (
          <div className={e.vazio}>
            {processos.length === 0 ? 'Ainda não há processos nesta campanha.' : 'Nenhum processo com estes filtros.'}
          </div>
        ) : (
          <div className={e.quadro}>
            <table className={e.tabela}>
              <thead>
                <tr>
                  <th>Cliente</th><th>Estado</th><th className={e.esconderPequeno}>Progresso</th>
                  <th className={e.num}>Rend.</th><th className={e.num}>Docs</th>
                  <th className={e.num}>Msg</th><th>Pagamento</th><th>Desde</th>
                </tr>
              </thead>
              <tbody>
                {visiveis.map((p) => {
                  const est = estadoDe(String(p.estado));
                  const { indice, total } = posicao(String(p.estado));
                  return (
                    <tr key={String(p.id)} className={e.linhaClicavel} onClick={() => abrir(String(p.id))}>
                      <td>
                        <div className={e.cliente}>
                          <span className={e.avatarPequeno}>{iniciais(String(p.cliente || '?'))}</span>
                          <div>
                            <button type="button" className={e.nome}
                                    onClick={(ev) => { ev.stopPropagation(); abrir(String(p.id)); }}>
                              {String(p.cliente)}
                            </button>
                            <span className={e.sub}>NIF {String(p.nif || '—')}</span>
                          </div>
                        </div>
                      </td>
                      <td><Pilula estado={String(p.estado)} /></td>
                      <td className={e.esconderPequeno}>
                        <div className={e.progresso} title={`Passo ${indice + 1} de ${total}`}>
                          <span style={{ inlineSize: `${((indice + 1) / total) * 100}%` }} data-desvio={est?.desvio} />
                        </div>
                      </td>
                      <td className={e.num}>{String(p.rendimentos)}</td>
                      <td className={e.num}>
                        {String(p.documentos)}
                        {Number(p.por_rever) > 0 && <span className={e.ponto} title={`${p.por_rever} por abrir`} />}
                      </td>
                      <td className={e.num}>
                        {Number(p.por_responder) > 0
                          ? <button type="button" className={e.badgeAzul}
                                    onClick={(ev) => { ev.stopPropagation(); abrir(String(p.id), 'mensagens'); }}>
                              {String(p.por_responder)} nova{Number(p.por_responder) > 1 ? 's' : ''}
                            </button>
                          : String(p.mensagens)}
                      </td>
                      <td>
                        {p.pago
                          ? <span className={e.etiqueta} data-tom="ok">Pago</span>
                          : p.pagamento === 'pending'
                            ? <span className={e.etiqueta} data-tom="atencao">A aguardar</span>
                            : emRecolha(String(p.estado))
                              ? <span className={e.etiqueta}>—</span>
                              : <span className={e.etiqueta} data-tom="erro">Por pagar</span>}
                        {p.dois_fatores ? <span className={e.etiqueta} data-tom="atencao">2FA</span> : null}
                      </td>
                      <td className={e.sub}>{dia(p.desde)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

function Conversas({ dados, abrir }: { dados: Dados; abrir: (p: string, aba?: string) => void }) {
  const conversas = (dados.conversas as Linha[]) || [];
  if (conversas.length === 0) return <div className={e.vazio}>Ainda não há conversas.</div>;
  return (
    <section className={e.cartao}>
      <ul className={e.listaConversas}>
        {conversas.map((c) => (
          <li key={String(c.processo)}>
            <button type="button" className={e.conversa} onClick={() => abrir(String(c.processo), 'mensagens')}>
              <span className={e.avatarPequeno}>{iniciais(String(c.cliente || '?'))}</span>
              <span className={e.conversaTexto}>
                <strong>{String(c.cliente)}</strong>
                <span>{String(c.resumo || '')}</span>
              </span>
              <span className={e.conversaFim}>
                <span className={e.sub}>{dia(c.ultima)}</span>
                {c.por_responder
                  ? <span className={e.badgeAzul}>Por responder</span>
                  : <span className={e.etiqueta} data-tom="ok">Respondido</span>}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function Pagamentos({ dados, abrir }:
  { dados: Dados; abrir: (p: string, aba?: string) => void }) {
  const pagamentos = (dados.pagamentos as Linha[]) || [];
  // A vista de pagamentos não traz totais: contam-se aqui.
  const pagos = pagamentos.filter((p) => p.estado === 'paid');
  return (
    <>
      <div className={e.indicadores}>
        <Indicador valor={euros(pagos.reduce((t, p) => t + Number(p.total || 0), 0))} rotulo="Recebido" destaque />
        <Indicador valor={pagos.length} rotulo="Processos pagos" />
        <Indicador valor={pagamentos.filter((p) => p.estado === 'pending').length} rotulo="A aguardar liquidação" />
        <Indicador valor={pagamentos.filter((p) => p.estado === 'failed').length} rotulo="Falhados" />
      </div>
      <section className={e.cartao}>
        {pagamentos.length === 0 ? <div className={e.vazio}>Ainda não há pagamentos.</div> : (
          <div className={e.quadro}>
            <table className={e.tabela}>
              <thead><tr><th>Cliente</th><th>Estado</th><th className={e.num}>Total</th>
                <th className={e.num}>Desconto</th><th>Criado</th><th>Pago</th></tr></thead>
              <tbody>
                {pagamentos.map((p) => (
                  <tr key={String(p.id)} className={e.linhaClicavel} onClick={() => abrir(String(p.processo), 'pagamento')}>
                    <td><span className={e.nomeSimples}>{String(p.cliente)}</span></td>
                    <td>
                      <span className={e.etiqueta}
                            data-tom={p.estado === 'paid' ? 'ok' : p.estado === 'failed' ? 'erro' : 'atencao'}>
                        {PAGAMENTOS[String(p.estado)] || String(p.estado)}
                      </span>
                    </td>
                    <td className={e.num}>{euros(p.total)}</td>
                    <td className={e.num}>{p.desconto ? euros(p.desconto) : '—'}</td>
                    <td className={e.sub}>{dia(p.criado)}</td>
                    <td className={e.sub}>{dia(p.pago_em)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

function Alertas({ dados, abrir }: { dados: Dados; abrir: (p: string, aba?: string) => void }) {
  const router = useRouter();
  const [resolvidos, setResolvidos] = useState<string[]>([]);
  const [, comecar] = useTransition();
  const alertas = ((dados.alertas as Linha[]) || []).filter((a) => !resolvidos.includes(String(a.id)));
  if (alertas.length === 0) return <div className={e.vazio}>Nada por resolver.</div>;
  return (
    <section className={e.cartao}>
      <ul className={e.listaAlertas}>
        {alertas.map((a) => {
          const info = ALERTAS[String(a.tipo)];
          return (
            <li key={String(a.id)} data-urgente={info?.urgente}>
              <div>
                <strong>{info?.rotulo || String(a.tipo)}</strong>
                <span className={e.sub}>
                  {String(a.cliente)}{a.pessoa ? ` · ${String(a.pessoa)}` : ''} · {dia(a.em)}
                </span>
              </div>
              <div className={e.acoesLinha}>
                {Boolean(a.processo) && (
                  <button type="button" className="btn btn-secundario" onClick={() => abrir(String(a.processo))}>
                    Abrir processo
                  </button>
                )}
                <button type="button" className="btn-texto"
                        onClick={() => comecar(async () => {
                          const r = await resolverAlertaDoGabinete(String(a.id));
                          if (r.ok) { setResolvidos((x) => [...x, String(a.id)]); router.refresh(); }
                        })}>
                  Marcar como resolvido
                </button>
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/* ------------------------------------------------------------ peças */

function Indicador({ valor, rotulo, destaque }: { valor: number | string; rotulo: string; destaque?: boolean }) {
  return (
    <div className={e.indicador} data-destaque={destaque}>
      <strong>{valor}</strong>
      <span>{rotulo}</span>
    </div>
  );
}
