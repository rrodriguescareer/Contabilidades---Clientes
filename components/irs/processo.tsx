'use client';
import { useActionState, useEffect, useRef, useState, useTransition } from 'react';
import { descarregarDocumento, enviarMensagem, verSenhaFinancas } from '@/lib/irs-actions';
import { posicao, estadoDe, type Prontidao } from '@/lib/fluxo';
import { AMBITOS, DEDUCOES, SEPARADORES, pertence } from './separadores';
import { Avanco } from './avanco';
import { TestesCegid } from './integracoes';
import { Pilula } from './pilula';
import { PAGAMENTOS } from './estados';
import e from './gabinete.module.css';

type Dados = Record<string, unknown>;
type Membro = {
  id: string; nome: string; nascimento: string | null; nif: string | null; relacao: string;
  dois_fatores: boolean; tem_senha: boolean; consultas: number; ultima_consulta: string | null;
};
type Rendimento = {
  id: string; categoria: string; tipo: string | null; titulo: string | null; titular: string | null;
  imovel: string | null; valor: number | null; nota: string; irs_jovem: boolean;
  estuda_trabalha: boolean; ambito: string | null; compra_em: string | null; venda_em: string | null;
  compra: number | null; venda: number | null; despesas: number | null;
  hpp: boolean; hpp_credito: number | null; hpp_feito: boolean;
};
type Documento = {
  id: string; tipo: string; descricao: string | null; categoria: string | null; nome: string;
  tamanho: number; estado: string; em: string; imovel: string | null; descargas: number;
};
type Mensagem = { id: string; corpo: string; em: string; do_gabinete: boolean };
type Evento = { id: string; titulo: string; corpo: string; em: string };

const euros = (c: number | null | undefined) =>
  c == null ? '—' : (c / 100).toLocaleString('pt-PT', { style: 'currency', currency: 'EUR' });
const dia = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleDateString('pt-PT') : '—');
const hora = (iso: string) =>
  new Date(iso).toLocaleString('pt-PT', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const RELACOES: Record<string, string> = {
  titular: 'Titular', conjuge: 'Cônjuge', descendente: 'Descendente', ascendente: 'Ascendente', outro: 'Outro',
};
const RESIDENCIAS: Record<string, string> = {
  continente: 'Continente', acores: 'Açores', madeira: 'Madeira', ue: 'União Europeia', fora_ue: 'Fora da UE',
};

const ABAS = [
  { id: 'resumo', rotulo: 'Resumo' },
  { id: 'agregado', rotulo: 'Agregado' },
  { id: 'rendimentos', rotulo: 'Rendimentos e benefícios' },
  { id: 'documentos', rotulo: 'Documentos' },
  { id: 'mensagens', rotulo: 'Mensagens' },
  { id: 'pagamento', rotulo: 'Pagamento' },
  { id: 'historico', rotulo: 'Histórico' },
] as const;

/* O processo aberto, dentro da consola. A mesma organização do cliente —
   Agregado, e Rendimentos e benefícios com os nove separadores — mas para
   conferir: só leitura, com o que eu preciso ao lado (senha, descargas,
   fluxo, mensagens). */
export function Processo({ dados, processo, abaInicial, aoMudar }:
  { dados: Dados; processo: string; abaInicial?: string; aoMudar: () => void }) {
  const cab = (dados.cabecalho as Record<string, unknown>) || {};
  const membros = (dados.membros as Membro[]) || [];
  const rendimentos = (dados.rendimentos as Rendimento[]) || [];
  const documentos = (dados.documentos as Documento[]) || [];
  const mensagens = (dados.mensagens as Mensagem[]) || [];
  const eventos = (dados.eventos as Evento[]) || [];
  const prontidao = (dados.prontidao as Prontidao[]) || [];
  const checkout = (dados.checkout as Record<string, unknown> | null) || null;

  const [aba, setAba] = useState<string>(ABAS.some((a) => a.id === abaInicial) ? abaInicial! : 'resumo');
  const trocar = (id: string) => {
    setAba(id);
    const url = new URL(window.location.href);
    url.searchParams.set('aba', id);
    window.history.replaceState(null, '', url);
  };

  const estado = String(cab.estado || '');
  const { indice, total } = posicao(estado);
  const porResponder = (() => {
    let n = 0;
    for (let i = mensagens.length - 1; i >= 0 && !mensagens[i].do_gabinete; i--) n++;
    return n;
  })();
  const porAbrir = documentos.filter((d) => d.descargas === 0).length;

  const contagem: Record<string, number | undefined> = {
    agregado: membros.length,
    rendimentos: rendimentos.length,
    documentos: documentos.length,
    mensagens: porResponder || undefined,
  };

  return (
    <div className={e.processo}>
      <section className={`${e.cartao} ${e.cabecalho}`}>
        <div className={e.identidade}>
          <span className={e.avatarGrande}>
            {String(cab.cliente || '?').split(/\s+/).slice(0, 2).map((p) => p[0]).join('').toUpperCase()}
          </span>
          <div>
            <h2>{String(cab.cliente || 'Processo')}</h2>
            <p className={e.sub}>
              NIF {String(cab.nif || '—')}
              {cab.residencia ? ` · ${RESIDENCIAS[String(cab.residencia)] || String(cab.residencia)}` : ''}
              {cab.morada ? ` · ${String(cab.morada)}` : ''}
            </p>
            <p className={e.contactos}>
              {cab.email ? <a href={`mailto:${String(cab.email)}`}>{String(cab.email)}</a> : null}
              {cab.telefone ? <a href={`tel:${String(cab.telefone).replace(/\s/g, '')}`}>{String(cab.telefone)}</a> : null}
            </p>
          </div>
        </div>
        <div className={e.estadoCabecalho}>
          <Pilula estado={estado} />
          <span className={e.sub}>Passo {indice + 1} de {total} · desde {dia(String(cab.desde || ''))}</span>
          <div className={e.acoesCabecalho}>
            <a className="btn btn-secundario btn-pequeno" href={`/relatorio/${processo}`} target="_blank" rel="noopener">
              Relatório do processo
            </a>
            <a className="btn btn-secundario btn-pequeno" href={`/relatorio/${processo}/atividade`} target="_blank" rel="noopener"
               title="Registo cronológico de todos os passos, para responder a uma contestação de pagamento">
              Relatório de atividade (prova)
            </a>
          </div>
        </div>
      </section>

      <nav className={e.abas} role="tablist" aria-label="Separadores do processo">
        {ABAS.map((a) => (
          <button key={a.id} type="button" role="tab" aria-selected={aba === a.id}
                  className={e.aba} onClick={() => trocar(a.id)}>
            {a.rotulo}
            {contagem[a.id] != null && (
              <span className={a.id === 'mensagens' ? e.badgeAzul : e.contagemAba}>{contagem[a.id]}</span>
            )}
          </button>
        ))}
      </nav>

      {aba === 'resumo' && (
        <>
          <Avanco processo={processo} estado={estado} aoMudar={aoMudar} prontidaoInicial={prontidao} />
          <div className={e.indicadores}>
            <div className={e.indicador}><strong>{membros.length}</strong><span>No agregado</span></div>
            <div className={e.indicador}><strong>{rendimentos.length}</strong><span>Rendimentos declarados</span></div>
            <div className={e.indicador} data-destaque={porAbrir > 0}>
              <strong>{documentos.length}</strong>
              <span>Documentos{porAbrir ? ` · ${porAbrir} por abrir` : ''}</span>
            </div>
            <div className={e.indicador}>
              <strong>{checkout ? euros(checkout.total as number) : '—'}</strong>
              <span>{checkout ? PAGAMENTOS[String(checkout.estado)] || String(checkout.estado) : 'Sem pagamento'}</span>
            </div>
          </div>
          {cab.valor_final != null && (
            <p className={cab.sentido === 'refund' ? 'aviso-positivo' : 'aviso-atencao'}>
              Valor apurado: {euros(cab.valor_final as number)} {cab.sentido === 'refund' ? 'a reembolsar' : 'a pagar'}.
            </p>
          )}
        </>
      )}

      {aba === 'agregado' && <Agregado membros={membros} representante={cab.representante as Record<string, string> | null} />}
      {aba === 'rendimentos' && <Rendimentos dados={dados} membros={membros} rendimentos={rendimentos} documentos={documentos} aoMudar={aoMudar} />}
      {aba === 'documentos' && (
        <section className={e.cartao}>
          <h3 className={e.tituloCartao}>Todos os documentos</h3>
          <Documentos documentos={documentos} aoMudar={aoMudar} />
        </section>
      )}
      {aba === 'mensagens' && (
        <Conversa processo={processo} conta={String(cab.conta || '')} mensagens={mensagens} aoMudar={aoMudar} />
      )}
      {aba === 'pagamento' && <Pagamento checkout={checkout} processo={processo} />}
      {aba === 'historico' && (
        <section className={e.cartao}>
          <h3 className={e.tituloCartao}>Histórico do processo</h3>
          {eventos.length === 0 ? <div className={e.vazio}>Ainda sem movimentos.</div> : (
            <ol className="percurso">
              {eventos.map((ev, i) => (
                <li key={ev.id} data-estado={i === 0 ? 'atual' : 'feito'}>
                  <span className="marca-passo" aria-hidden="true" />
                  <div>
                    <strong>{ev.titulo}</strong>
                    {ev.corpo && <p>{ev.corpo}</p>}
                    <p className="suave">{hora(ev.em)}</p>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </section>
      )}
      {estadoDe(estado) === null && <p className="suave">Estado desconhecido: {estado}</p>}
    </div>
  );
}

/* -------------------------------------------------------------- agregado */

function Agregado({ membros, representante }: { membros: Membro[]; representante: Record<string, string> | null }) {
  return (
    <section className={e.cartao}>
      <h3 className={e.tituloCartao}>Agregado familiar</h3>
      <div className={e.quadro}>
        <table className={e.tabela}>
          <thead>
            <tr><th>Nome</th><th>Relação</th><th>NIF</th><th>Nascimento</th><th>Senha das Finanças</th></tr>
          </thead>
          <tbody>
            {membros.map((m) => (
              <tr key={m.id}>
                <td>
                  <span className={e.nomeSimples}>{m.nome}</span>
                  {m.dois_fatores && <span className={e.etiqueta} data-tom="atencao">2FA</span>}
                </td>
                <td>{RELACOES[m.relacao] || m.relacao}</td>
                <td className={e.mono}>{m.nif || '—'}</td>
                <td>{dia(m.nascimento)}</td>
                <td><Senha membro={m} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {membros.some((m) => m.dois_fatores) && (
        <p className="aviso-atencao">Há pessoas com dois fatores ativo: é preciso contactar o cliente na altura da submissão.</p>
      )}
      {representante && (
        <p className={e.sub}>
          Representante fiscal: {representante.nome} · NIF {representante.nif} · {representante.email} · {representante.telefone}
        </p>
      )}
    </section>
  );
}

/* Ver a senha regista a consulta (o cliente vê-a) e esconde-a ao fim de 30 s. */
function Senha({ membro }: { membro: Membro }) {
  const [senha, setSenha] = useState<string | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [copiada, setCopiada] = useState(false);
  const [aVer, comecar] = useTransition();

  useEffect(() => {
    if (!senha) return;
    const t = window.setTimeout(() => setSenha(null), 30_000);
    return () => window.clearTimeout(t);
  }, [senha]);

  if (!membro.tem_senha) return <span className={e.etiqueta} data-tom="erro">Por indicar</span>;

  if (senha) {
    return (
      <span className={e.senhaVisivel}>
        <code>{senha}</code>
        <button type="button" className="btn-texto"
                onClick={async () => { await navigator.clipboard.writeText(senha); setCopiada(true); }}>
          {copiada ? 'Copiada' : 'Copiar'}
        </button>
        <button type="button" className="btn-texto" onClick={() => setSenha(null)}>Esconder</button>
      </span>
    );
  }

  return (
    <span className={e.senhaVisivel}>
      <button type="button" className="btn btn-secundario btn-pequeno" disabled={aVer}
              onClick={() => comecar(async () => {
                setErro(null); setCopiada(false);
                const r = await verSenhaFinancas(membro.id);
                if (r.ok) setSenha(r.senha); else setErro(r.erro);
              })}>
        {aVer ? 'A abrir…' : 'Ver senha'}
      </button>
      <span className={e.sub}>
        {membro.consultas ? `${membro.consultas} consulta${membro.consultas > 1 ? 's' : ''} · última ${dia(membro.ultima_consulta)}` : 'Nunca consultada'}
      </span>
      {erro && <span className="aviso-critico">{erro}</span>}
    </span>
  );
}

/* ---------------------------------------------------- rendimentos (tabs) */

function Rendimentos({ dados, membros, rendimentos, documentos, aoMudar }:
  { dados: Dados; membros: Membro[]; rendimentos: Rendimento[]; documentos: Documento[]; aoMudar: () => void }) {
  const notas = (dados.notas as Record<string, string>) || {};
  const deducoes = (dados.deducoes as Record<string, unknown>) || {};
  const imoveis = (dados.imoveis as { id: string; nome: string; descricao?: string }[]) || [];
  const separadores = [...SEPARADORES.map((s) => ({ id: s.id, titulo: s.titulo, categoria: s.categoria })),
    { id: DEDUCOES.id, titulo: DEDUCOES.titulo, categoria: 'deduction' }];
  const [ativo, setAtivo] = useState(separadores[0].id);

  const nome = (id: string | null) => membros.find((m) => m.id === id)?.nome || '—';
  const imovel = (id: string | null) => imoveis.find((i) => i.id === id)?.nome || '—';
  const s = separadores.find((x) => x.id === ativo)!;
  const linhas = s.id === 'deduction' ? [] : rendimentos.filter((r) => pertence(r, s));
  const docs = documentos.filter((d) => d.categoria === s.categoria);
  const maisValias = s.id === 'property_sale' || s.id === 'securities_sale';
  const porImovel = s.id === 'property_rent' || s.id === 'property_sale';

  const conta = (sep: { id: string; categoria: string }) =>
    sep.id === 'deduction'
      ? documentos.filter((d) => d.categoria === 'deduction').length
      : rendimentos.filter((r) => pertence(r, sep)).length;

  return (
    <section className={e.cartao}>
      <div className={e.subAbas} role="tablist" aria-label="Tipos de rendimento">
        {separadores.map((sep) => {
          const n = conta(sep);
          return (
            <button key={sep.id} type="button" role="tab" aria-selected={ativo === sep.id}
                    className={e.subAba} data-vazio={n === 0} onClick={() => setAtivo(sep.id)}>
              {sep.titulo}
              {n > 0 && <span className={e.contagemAba}>{n}</span>}
            </button>
          );
        })}
      </div>

      {s.id === 'deduction' ? (
        <Deducoes deducoes={deducoes} nome={nome} />
      ) : linhas.length === 0 ? (
        <div className={e.vazio}>O cliente não declarou nada em {s.titulo.toLowerCase()}.</div>
      ) : (
        <div className={e.quadro}>
          <table className={e.tabela}>
            <thead>
              <tr>
                <th>Titular</th>
                {porImovel && <th>Imóvel</th>}
                {s.id === 'foreign_income' && <th>Âmbito</th>}
                <th>Tipo</th>
                {maisValias ? <><th>Compra</th><th>Venda</th><th className={e.num}>Despesas</th></>
                  : <th className={e.num}>Valor</th>}
                <th>Sinais</th>
              </tr>
            </thead>
            <tbody>
              {linhas.map((r) => (
                <tr key={r.id}>
                  <td>
                    <span className={e.nomeSimples}>{nome(r.titular)}</span>
                    {r.nota && <span className={e.notaLinha}>{r.nota}</span>}
                  </td>
                  {porImovel && <td>{imovel(r.imovel)}</td>}
                  {s.id === 'foreign_income' && <td>{AMBITOS.find((a) => a.id === r.ambito)?.titulo || r.ambito || '—'}</td>}
                  <td>{r.tipo || r.titulo || '—'}</td>
                  {maisValias ? (
                    <>
                      <td>{euros(r.compra)}<span className={e.sub}> · {dia(r.compra_em)}</span></td>
                      <td>{euros(r.venda)}<span className={e.sub}> · {dia(r.venda_em)}</span></td>
                      <td className={e.num}>{euros(r.despesas)}</td>
                    </>
                  ) : <td className={e.num}>{euros(r.valor)}</td>}
                  <td>
                    {r.irs_jovem && <span className={e.etiqueta} data-tom="info">IRS Jovem</span>}
                    {r.estuda_trabalha && <span className={e.etiqueta} data-tom="info">Estuda e trabalha</span>}
                    {r.hpp && <span className={e.etiqueta} data-tom="info">Reinvest. HPP{r.hpp_feito ? ' feito' : ''}{r.hpp_credito ? ` · crédito ${euros(r.hpp_credito)}` : ''}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className={e.notaCliente}>
        <h4>Nota do cliente</h4>
        <p>{notas[s.categoria] || <span className={e.sub}>Sem nota.</span>}</p>
      </div>

      <div>
        <h4 className={e.tituloSecao}>Documentos deste separador</h4>
        <Documentos documentos={docs} aoMudar={aoMudar} />
      </div>
    </section>
  );
}

function Deducoes({ deducoes, nome }: { deducoes: Record<string, unknown>; nome: (id: string | null) => string }) {
  const linha = (rotulo: string, valor: boolean | undefined | null, extra?: string) => (
    <li>
      <span>{rotulo}</span>
      <span className={e.etiqueta} data-tom={valor ? 'ok' : undefined}>{valor ? 'Sim' : 'Não'}</span>
      {extra && valor ? <span className={e.sub}>{extra}</span> : null}
    </li>
  );
  if (Object.keys(deducoes).length === 0) return <div className={e.vazio}>O cliente ainda não preencheu as deduções.</div>;
  return (
    <ul className={e.listaDeducoes}>
      {linha('Considerar as despesas do e-fatura', deducoes.use_efatura !== false)}
      {linha('Imóvel arrendado', Boolean(deducoes.rented_home),
        `Contrato ${deducoes.contract_reported ? 'comunicado' : 'não comunicado'} · recibos ${deducoes.rent_receipts ? 'sim' : 'não'}${deducoes.rent_receipts === false ? ` · faturas do senhorio ${deducoes.landlord_invoices ? 'sim' : 'não'}` : ''}`)}
      {linha('PPR', Boolean(deducoes.ppr), `Titular: ${nome(String(deducoes.ppr_person_id || ''))}`)}
      {linha('Despesas com ascendentes', Boolean(deducoes.ascendant_expenses))}
    </ul>
  );
}

/* ------------------------------------------------------------ documentos */

function Documentos({ documentos, aoMudar }: { documentos: Documento[]; aoMudar: () => void }) {
  const [erro, setErro] = useState<string | null>(null);
  const [aAbrir, setAAbrir] = useState<string | null>(null);
  if (documentos.length === 0) return <div className={e.vazio}>Sem documentos.</div>;
  return (
    <>
      {erro && <p className="aviso-critico">{erro}</p>}
      <div className={e.quadro}>
        <table className={e.tabela}>
          <thead><tr><th>Tipo</th><th>Descrição</th><th>Imóvel</th><th>Enviado</th><th>Aberto</th><th /></tr></thead>
          <tbody>
            {documentos.map((d) => (
              <tr key={d.id}>
                <td>{d.tipo}</td>
                <td>{d.descricao || <span className={e.sub}>{d.nome}</span>}</td>
                <td>{d.imovel || '—'}</td>
                <td className={e.sub}>{dia(d.em)}</td>
                <td>
                  {d.descargas > 0
                    ? <span className={e.etiqueta} data-tom="ok">{d.descargas}×</span>
                    : <span className={e.etiqueta} data-tom="atencao">Por abrir</span>}
                </td>
                <td className={e.direita}>
                  <button type="button" className="btn btn-secundario btn-pequeno" disabled={aAbrir === d.id}
                          onClick={async () => {
                            setErro(null); setAAbrir(d.id);
                            const r = await descarregarDocumento(d.id);
                            setAAbrir(null);
                            if (!r.ok) { setErro(r.erro); return; }
                            window.location.assign(r.url);
                            aoMudar();
                          }}>
                    {aAbrir === d.id ? 'A abrir…' : 'Descarregar'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

/* ------------------------------------------------------------- mensagens */

function Conversa({ processo, conta, mensagens, aoMudar }:
  { processo: string; conta: string; mensagens: Mensagem[]; aoMudar: () => void }) {
  const [estado, accao, aEnviar] = useActionState(enviarMensagem, null);
  const forma = useRef<HTMLFormElement>(null);
  const fundo = useRef<HTMLDivElement>(null);

  /* Cada resposta só dispara um refresh. Sem isto, o refresh trazia um
     aoMudar novo, o efeito voltava a correr com o mesmo "ok" e recarregava
     sem fim. */
  const tratado = useRef<unknown>(null);
  useEffect(() => {
    if (estado?.ok && tratado.current !== estado) {
      tratado.current = estado;
      forma.current?.reset();
      aoMudar();
    }
  }, [estado, aoMudar]);
  useEffect(() => {
    fundo.current?.scrollTo({ top: fundo.current.scrollHeight });
  }, [mensagens.length]);

  return (
    <section className={`${e.cartao} ${e.chat}`}>
      <div className={e.mensagens} ref={fundo}>
        {mensagens.length === 0
          ? <div className={e.vazio}>Ainda não há mensagens neste processo. Escreva a primeira.</div>
          : mensagens.map((m) => (
            <article key={m.id} className={e.balao} data-meu={m.do_gabinete}>
              <p>{m.corpo}</p>
              <span>{m.do_gabinete ? 'Eu' : 'Cliente'} · {hora(m.em)}</span>
            </article>
          ))}
      </div>
      <form ref={forma} action={accao} className={e.compor}>
        <input type="hidden" name="conta" value={conta} />
        <input type="hidden" name="processo" value={processo} />
        <textarea name="corpo" rows={2} required maxLength={4000} className="entrada"
                  placeholder="Escrever ao cliente…  (Enter envia, Shift+Enter muda de linha)"
                  onKeyDown={(ev) => {
                    if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); forma.current?.requestSubmit(); }
                  }} />
        <button type="submit" className="btn" disabled={aEnviar}>{aEnviar ? 'A enviar…' : 'Enviar'}</button>
      </form>
      {estado && !estado.ok && <p className="aviso-critico">{estado.erro}</p>}
    </section>
  );
}

/* ------------------------------------------------------------- pagamento */

function Pagamento({ checkout, processo }: { checkout: Record<string, unknown> | null; processo: string }) {
  const detalhe = (checkout?.detalhe as { items?: { code: string; label: string; amount_cents: number }[]; discount_code?: string } | null) || null;
  return (
    <>
      <section className={e.cartao}>
        <h3 className={e.tituloCartao}>Pagamento</h3>
        {!checkout ? <div className={e.vazio}>O cliente ainda não iniciou o pagamento.</div> : (
          <>
            <p>
              <span className={e.etiqueta} data-tom={checkout.estado === 'paid' ? 'ok' : 'atencao'}>
                {PAGAMENTOS[String(checkout.estado)] || String(checkout.estado)}
              </span>
              {checkout.pago_em ? <span className={e.sub}> em {hora(String(checkout.pago_em))}</span> : null}
            </p>
            <table className="tabela-preco">
              <tbody>
                {(detalhe?.items || []).map((i) => (
                  <tr key={i.code}><td>{i.label}</td><td>{euros(i.amount_cents)}</td></tr>
                ))}
                {checkout.desconto ? (
                  <tr className="desconto"><td>Desconto{detalhe?.discount_code ? ` (${detalhe.discount_code})` : ''}</td><td>−{euros(checkout.desconto as number)}</td></tr>
                ) : null}
                <tr className="total"><td>Total</td><td>{euros(checkout.total as number)}</td></tr>
              </tbody>
            </table>
          </>
        )}
      </section>
      <TestesCegid processo={processo} />
    </>
  );
}
