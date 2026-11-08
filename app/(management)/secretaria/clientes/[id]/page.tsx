import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ownerSession } from '@/lib/auth';
import { uuid } from '@/lib/data';
import { Avisos } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { Faixa, IniciarProcesso, Numero, SeletorPeriodo } from '@/components/secretaria/comum';
import { Dialogo } from '@/components/secretaria/dialogo';
import { Importar } from '@/components/secretaria/importar';
import { EditorModelo } from '@/components/secretaria/editor-modelo';
import { CamposCadencia } from '@/components/secretaria/cadencia';
import { TabelaPendencias, type LinhaPendencia } from '@/components/secretaria/tabela-pendencias';
import {
  cancelarProcesso, eliminarRecorrente, gerarRecorrentes, guardarCliente, guardarContacto, guardarPendencia, guardarRecorrente, mudarContacto, trazerContactosDoPortal,
} from '@/lib/secretaria-actions';
import { ESTADOS_ENVIO, MOTIVOS, TIPOS, cadenciaTexto, dataHoraPt, dataPt, hojeLisboa, lerPeriodo, limiteSugerido, type Cadencia } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Ficha do cliente · Secretária' };

const ABAS = [['pendencias', 'Pendências'], ['contactos', 'Contactos'], ['modelos', 'Modelos'], ['historico', 'Histórico'], ['definicoes', 'Definições']] as const;
type Procura = { aba?: string; modo?: string; p?: string; erro?: string; mensagem?: string };
type Processo = { id: string; estado: string; motivo: string | null; dia_limite: string; proximo_envio: string | null; iniciado_em: string; terminado_em: string | null; insistencias: number; ultimo_contacto: string | null };
type Contacto = { id: string; nome: string; email: string; principal: boolean; em_cc: boolean; contactavel: boolean };

export default async function FichaCliente({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Procura> }) {
  const { client } = await ownerSession();
  const [{ id }, pedido] = await Promise.all([params, searchParams]);
  if (!uuid(id)) notFound();
  const aba = ABAS.some(([k]) => k === pedido.aba) ? pedido.aba! : 'pendencias';
  const base = `/secretaria/clientes/${id}`;
  const periodo = lerPeriodo(pedido.modo, pedido.p);
  const qs = new URLSearchParams();
  qs.set('aba', aba);
  if (pedido.modo) qs.set('modo', pedido.modo);
  if (pedido.p) qs.set('p', pedido.p);
  const aqui = `${base}?${qs.toString()}`;

  const [{ data: empresa }, { data: processo }, { data: definicoes }, { data: contactos }, { data: abertas }] = await Promise.all([
    client.from('companies').select('id,name,nif,active').eq('id', id).maybeSingle(),
    client.from('secretaria_processos').select('id,estado,motivo,dia_limite,proximo_envio,iniciado_em,terminado_em,insistencias,ultimo_contacto').eq('company_id', id).eq('estado', 'em_curso').maybeSingle(),
    client.from('secretaria_definicoes').select('aprovar,dia_limite,cadencia').maybeSingle(),
    client.from('secretaria_contactos').select('id,nome,email,principal,em_cc,contactavel').eq('company_id', id).order('principal', { ascending: false }).order('nome'),
    client.from('secretaria_pendencias').select('periodo').eq('company_id', id).eq('estado', 'pendente').eq('acompanhar', true).limit(500),
  ]);
  if (!empresa) notFound();
  const lista = (contactos ?? []) as Contacto[];
  const temContacto = lista.some((c) => c.principal && c.contactavel);
  const numAbertas = (abertas ?? []).length;
  const limite = limiteSugerido(definicoes?.dia_limite ?? 10, (abertas ?? []).map((x) => String(x.periodo).slice(0, 7)));
  const proc = processo as Processo | null;

  return (
    <div className={s.pagina}>
      <nav className={s.migalhas} aria-label="Caminho"><Link prefetch={false} href="/secretaria/clientes">Clientes</Link><span>›</span><span>{empresa.name}</span></nav>
      <Avisos erro={pedido.erro} mensagem={pedido.mensagem} />
      <div className={s.fichaCabeca}>
        <div>
          <h2>{empresa.name}</h2>
          <p>NIF {empresa.nif}</p>
        </div>
        <div className={s.acoes}>
          <Link prefetch={false} className="btn btn-secundario btn-sm" href={`/empresas/${id}`}>Abrir na gestão de empresas</Link>
        </div>
      </div>

      <nav className={s.abas} aria-label="Ficha do cliente">
        {ABAS.map(([k, n]) => <Link prefetch={false} key={k} href={`${base}?aba=${k}`} aria-current={aba === k ? 'page' : undefined}>{n}</Link>)}
      </nav>

      {proc && (
        <Faixa tom="positivo" acao={
          <form action={cancelarProcesso}>
            <input type="hidden" name="processo" value={proc.id} /><input type="hidden" name="voltar" value={aqui} />
            <Submeter className={s.acaoPequena} aDecorrer="A cancelar…">Cancelar processo</Submeter>
          </form>
        }>
          <span><strong>Processo em curso</strong>{proc.proximo_envio ? ` · Próximo envio a ${dataHoraPt(proc.proximo_envio)}` : ''} · termina a {dataPt(proc.dia_limite)}{proc.insistencias ? ` · ${proc.insistencias} insistência${proc.insistencias === 1 ? '' : 's'}` : ''}</span>
        </Faixa>
      )}

      {aba === 'pendencias' && <Pendencias id={id} periodo={periodo} aqui={aqui} base={base} pedido={pedido} tem={!proc && numAbertas > 0 && temContacto} semContacto={!temContacto && numAbertas > 0} limite={limite} aprovar={definicoes?.aprovar ?? 'primeiro'} />}
      {aba === 'contactos' && <Contactos id={id} lista={lista} aqui={aqui} />}
      {aba === 'modelos' && <Modelos id={id} aqui={aqui} nome={empresa.name} />}
      {aba === 'historico' && <Historico id={id} />}
      {aba === 'definicoes' && <Definicoes id={id} aqui={aqui} geral={(definicoes?.cadencia ?? null) as Cadencia | null} diaGeral={definicoes?.dia_limite ?? 10} />}
    </div>
  );
}

async function Pendencias({ id, periodo, aqui, base, pedido, tem, semContacto, limite, aprovar }: {
  id: string; periodo: ReturnType<typeof lerPeriodo>; aqui: string; base: string; pedido: Procura; tem: boolean; semContacto: boolean; limite: string; aprovar: string;
}) {
  const { client } = await ownerSession();
  const { data } = await client.from('secretaria_pendencias')
    .select('id,tipo,descricao,numero,data_documento,valor_cents,banco,origem,estado,acompanhar,documento_id,periodo')
    .eq('company_id', id).gte('periodo', periodo.desde).lte('periodo', periodo.ate)
    .order('data_documento', { ascending: true, nullsFirst: false }).limit(1000);
  const linhas = (data ?? []) as LinhaPendencia[];
  const validas = linhas.filter((l) => l.estado !== 'anulada');
  const recebidas = validas.filter((l) => ['recebida', 'associada'].includes(l.estado)).length;
  const porReceber = validas.filter((l) => l.estado === 'pendente').length;
  const acompanhadas = validas.filter((l) => l.estado === 'pendente' && l.acompanhar).length;
  const mesPadrao = periodo.modo === 'mensal' ? periodo.chave : hojeLisboa().slice(0, 7);

  return (
    <>
      <div className={s.numeros}>
        <Numero rotulo="Recebidas" valor={recebidas} />
        <Numero rotulo="Por receber" valor={porReceber} tom={porReceber ? 'atencao' : undefined} />
        <Numero rotulo="Em acompanhamento" valor={acompanhadas} />
        <Numero rotulo="Documentação entregue" valor={validas.length ? `${Math.round((recebidas / validas.length) * 100)}%` : '—'} />
      </div>

      {semContacto && <Faixa tom="atencao" acao={<Link prefetch={false} className={s.acaoPequena} href={`${base}?aba=contactos`}>Definir contacto</Link>}><span>Falta um contacto principal contactável para poder pedir estes documentos.</span></Faixa>}

      <div className={s.barraFerramentas}>
        <SeletorPeriodo periodo={periodo} caminho={`${base}?aba=pendencias`} />
        <div className={s.acoes}>
          <Dialogo rotulo="Importar ficheiro" titulo="Importar pendências" largo>
            <Importar empresa={id} periodoPadrao={mesPadrao} />
          </Dialogo>
          <Dialogo rotulo="Nova pendência" titulo="Nova pendência">
            <form action={guardarPendencia} className="pilha pilha-3">
              <input type="hidden" name="empresa" value={id} /><input type="hidden" name="voltar" value={aqui} />
              <div className={s.campos}>
                <label className="campo"><span>Tipo</span>
                  <select name="tipo" className="entrada" defaultValue="FT">{Object.entries(TIPOS).map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select>
                </label>
                <label className="campo"><span>N.º do documento</span><input name="numero" className="entrada" maxLength={80} /></label>
              </div>
              <label className="campo"><span>Origem (fornecedor ou descrição)</span><input name="descricao" className="entrada" maxLength={200} required /></label>
              <div className={s.campos}>
                <label className="campo"><span>Data do documento</span><input name="data" type="date" className="entrada" /></label>
                <label className="campo"><span>Valor</span><input name="valor" className="entrada" inputMode="decimal" placeholder="0,00" /></label>
                <label className="campo"><span>Período, se não tiver data</span><input name="periodo" type="month" className="entrada" defaultValue={mesPadrao} /></label>
                <label className="campo"><span>Banco (opcional)</span><input name="banco" className="entrada" maxLength={80} /></label>
              </div>
              <div className={s.linhaBotoes}><Submeter className="btn btn-sm" aDecorrer="A criar…">Criar pendência</Submeter></div>
            </form>
          </Dialogo>
          {tem && <IniciarProcesso empresa={id} limite={limite} voltar={aqui} aprovar={aprovar} />}
        </div>
      </div>

      <TabelaPendencias linhas={linhas} voltar={pedido.modo ? aqui : `${base}?aba=pendencias`} />
    </>
  );
}

function Contactos({ id, lista, aqui }: { id: string; lista: Contacto[]; aqui: string }) {
  const Alternar = ({ c, campo, valor, texto, classe }: { c: Contacto; campo: string; valor: boolean; texto: string; classe?: string }) => (
    <form action={mudarContacto}>
      <input type="hidden" name="id" value={c.id} /><input type="hidden" name="empresa" value={id} />
      <input type="hidden" name="campo" value={campo} /><input type="hidden" name="valor" value={String(valor)} /><input type="hidden" name="voltar" value={aqui} />
      <Submeter className={classe ?? s.acaoPequena} aDecorrer="…">{texto}</Submeter>
    </form>
  );
  return (
    <section className="pilha pilha-3">
      <div className={s.barraFerramentas}>
        <p className="suave">Quem recebe os pedidos. O contacto principal recebe o email; os outros, se estiverem em cópia.</p>
        <div className={s.acoes}>
          <form action={trazerContactosDoPortal}>
            <input type="hidden" name="empresa" value={id} /><input type="hidden" name="voltar" value={aqui} />
            <Submeter className="btn btn-secundario btn-sm" aDecorrer="A trazer…">Trazer utilizadores do portal</Submeter>
          </form>
          <Dialogo rotulo="Novo contacto" titulo="Novo contacto" classe="btn btn-sm">
            <form action={guardarContacto} className="pilha pilha-3">
              <input type="hidden" name="empresa" value={id} /><input type="hidden" name="voltar" value={aqui} />
              <label className="campo"><span>Nome</span><input name="nome" className="entrada" maxLength={120} required /></label>
              <label className="campo"><span>Email</span><input name="email" type="email" className="entrada" maxLength={254} required /></label>
              <label className="caixa"><input type="checkbox" name="principal" defaultChecked={!lista.some((c) => c.principal)} /><span>Contacto principal</span></label>
              <label className="caixa"><input type="checkbox" name="em_cc" /><span>Em cópia nos emails</span></label>
              <div className={s.linhaBotoes}><Submeter className="btn btn-sm">Guardar contacto</Submeter></div>
            </form>
          </Dialogo>
        </div>
      </div>
      {lista.length === 0 ? (
        <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Sem contactos</strong><span>Acrescente quem deve receber os pedidos.</span></div>
      ) : (
        <div className={s.envolve}>
          <table className={s.tabela}>
            <thead><tr><th>Nome</th><th>Email</th><th>Papel</th><th>Contactável</th><th className={s.direita}>Ações</th></tr></thead>
            <tbody>
              {lista.map((c) => (
                <tr key={c.id}>
                  <td data-rotulo=""><strong>{c.nome}</strong></td>
                  <td data-rotulo="Email" className={s.detalhe}>{c.email}</td>
                  <td data-rotulo="Papel">{c.principal ? <span className="etiqueta etiqueta-acao">Principal</span> : c.em_cc ? <span className="etiqueta">Em cópia</span> : '—'}</td>
                  <td data-rotulo="Contactável">{c.contactavel ? <span className="etiqueta etiqueta-positivo">Sim</span> : <span className="etiqueta etiqueta-critico">Não contactar</span>}</td>
                  <td data-rotulo="">
                    <div className={s.linhaAcoes}>
                      {!c.principal && <Alternar c={c} campo="principal" valor texto="Tornar principal" />}
                      {!c.principal && <Alternar c={c} campo="em_cc" valor={!c.em_cc} texto={c.em_cc ? 'Tirar de cópia' : 'Pôr em cópia'} />}
                      <Alternar c={c} campo="contactavel" valor={!c.contactavel} texto={c.contactavel ? 'Não contactar' : 'Voltar a contactar'} />
                      <Alternar c={c} campo="eliminar" valor texto="Eliminar" />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

async function Modelos({ id, aqui, nome }: { id: string; aqui: string; nome: string }) {
  const { client } = await ownerSession();
  const { data } = await client.from('secretaria_modelos').select('company_id,tipo,assunto,corpo').or(`company_id.eq.${id},company_id.is.null`);
  const modelo = (tipo: string) => (data ?? []).filter((m) => m.tipo === tipo).sort((a) => (a.company_id ? -1 : 1))[0];
  const proprio = (tipo: string) => (data ?? []).some((m) => m.tipo === tipo && m.company_id);
  return (
    <div className={s.duasIguais}>
      {[['pedido', 'Primeiro pedido'], ['insistencia', 'Insistência']].map(([t, n]) => (
        <EditorModelo key={t} titulo={n} tipo={t} empresa={id} voltar={aqui} proprio={proprio(t)} assunto={modelo(t)?.assunto ?? ''} corpo={modelo(t)?.corpo ?? ''} nomeEmpresa={nome} />
      ))}
    </div>
  );
}

async function Historico({ id }: { id: string }) {
  const { client } = await ownerSession();
  const [{ data: envios }, { data: processos }, { data: respostas }] = await Promise.all([
    client.from('secretaria_envios').select('id,tipo,estado,para,pendencias,criado_em,enviado_em,erro').eq('company_id', id).order('criado_em', { ascending: false }).limit(50),
    client.from('secretaria_processos').select('id,estado,motivo,dia_limite,iniciado_em,terminado_em,insistencias').eq('company_id', id).order('iniciado_em', { ascending: false }).limit(20),
    client.from('secretaria_respostas').select('id,texto,criado_em').eq('company_id', id).order('criado_em', { ascending: false }).limit(20),
  ]);
  return (
    <div className="pilha pilha-5">
      {(respostas ?? []).length > 0 && (
        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h3>Respostas do cliente</h3></div>
          {respostas!.map((r) => <div key={r.id} className={s.atividade}><strong className={s.detalhe}>{r.texto}</strong><span>{dataHoraPt(r.criado_em)}</span></div>)}
        </section>
      )}
      <section className="pilha pilha-3">
        <h3>Emails</h3>
        {(envios ?? []).length === 0 ? <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Ainda sem emails</strong></div> : (
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Tipo</th><th>Estado</th><th>Para</th><th>Documentos</th><th>Quando</th></tr></thead>
              <tbody>
                {envios!.map((e) => (
                  <tr key={e.id}>
                    <td data-rotulo="Tipo"><strong>{e.tipo === 'pedido' ? 'Pedido' : 'Insistência'}</strong></td>
                    <td data-rotulo="Estado"><span className={ESTADOS_ENVIO[e.estado].classe}>{ESTADOS_ENVIO[e.estado].nome}</span>{e.erro && <span className={s.segundo}>{e.erro}</span>}</td>
                    <td data-rotulo="Para" className={s.detalhe}>{e.para ?? '—'}</td>
                    <td data-rotulo="Documentos">{e.pendencias}</td>
                    <td data-rotulo="Quando" className={s.nowrap}>{dataHoraPt(e.enviado_em ?? e.criado_em)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
      <section className="pilha pilha-3">
        <h3>Processos</h3>
        {(processos ?? []).length === 0 ? <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Ainda sem processos</strong></div> : (
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Início</th><th>Dia limite</th><th>Insistências</th><th>Resultado</th></tr></thead>
              <tbody>
                {processos!.map((p) => (
                  <tr key={p.id}>
                    <td data-rotulo="Início">{dataHoraPt(p.iniciado_em)}</td>
                    <td data-rotulo="Dia limite">{dataPt(p.dia_limite)}</td>
                    <td data-rotulo="Insistências">{p.insistencias}</td>
                    <td data-rotulo="Resultado">{p.estado === 'em_curso' ? <span className="etiqueta etiqueta-acao">Em curso</span> : <span className="etiqueta">{MOTIVOS[p.motivo ?? ''] ?? 'Terminado'}</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}

async function Definicoes({ id, aqui, geral, diaGeral }: { id: string; aqui: string; geral: Cadencia | null; diaGeral: number }) {
  const { client } = await ownerSession();
  const [{ data: c }, { data: recorrentes }] = await Promise.all([
    client.from('secretaria_clientes').select('periodicidade,envio_automatico,dia_limite,cadencia,responsavel').eq('company_id', id).maybeSingle(),
    client.from('secretaria_recorrentes').select('id,tipo,descricao,banco').eq('company_id', id).order('criado_em'),
  ]);
  const hoje = hojeLisboa();
  const mesAnterior = new Date(Date.UTC(Number(hoje.slice(0, 4)), Number(hoje.slice(5, 7)) - 2, 1)).toISOString().slice(0, 7);
  return (
    <div className={s.duasIguais}>
      <form action={guardarCliente} className={s.bloco}>
        <input type="hidden" name="empresa" value={id} /><input type="hidden" name="voltar" value={aqui} />
        <div className={s.blocoTitulo}><h3>Acompanhamento</h3></div>
        <div className={s.campos}>
          <label className="campo"><span>Periodicidade</span>
            <select name="periodicidade" className="entrada" defaultValue={c?.periodicidade ?? 'mensal'}>
              <option value="mensal">Mensal</option><option value="trimestral">Trimestral</option><option value="isento">Isento</option>
            </select>
          </label>
          <label className="campo"><span>Dia limite (1 a 28)</span><input name="dia_limite" type="number" min={1} max={28} className="entrada" placeholder={`${diaGeral} (gabinete)`} defaultValue={c?.dia_limite ?? ''} /></label>
          <label className="campo"><span>Responsável</span><input name="responsavel" className="entrada" maxLength={120} defaultValue={c?.responsavel ?? ''} /></label>
        </div>
        <label className="caixa"><input type="checkbox" name="envio_automatico" defaultChecked={c?.envio_automatico ?? true} /><span>Envio automático de insistências</span></label>
        <label className="caixa"><input type="checkbox" name="proprio" defaultChecked={Boolean(c?.cadencia)} /><span>Usar calendário próprio (o do gabinete é: {cadenciaTexto(geral)})</span></label>
        <CamposCadencia inicial={(c?.cadencia ?? geral) as Cadencia | null} />
        <div className={s.linhaBotoes}><Submeter className="btn btn-sm">Guardar</Submeter></div>
      </form>

      <section className={s.bloco}>
        <div className={s.blocoTitulo}>
          <h3>Documentos que se repetem</h3>
          <p>Criados no dia 1 de cada mês, para o mês anterior.</p>
        </div>
        {(recorrentes ?? []).length === 0 ? (
          <p className="pequeno suave">Por exemplo, o extrato de cada banco. Evita registar à mão o que falta todos os meses.</p>
        ) : recorrentes!.map((r) => (
          <div key={r.id} className={s.linhaItem}>
            <span className={s.sigla}>{r.tipo === 'OUTRO' ? 'OUT' : r.tipo}</span>
            <div className={s.linhaTexto}><strong>{r.descricao}</strong>{r.banco && <span>{r.banco}</span>}</div>
            <form action={eliminarRecorrente}>
              <input type="hidden" name="id" value={r.id} /><input type="hidden" name="voltar" value={aqui} />
              <Submeter className={s.acaoPequena} aDecorrer="…">Retirar</Submeter>
            </form>
          </div>
        ))}
        <form action={guardarRecorrente} className="pilha pilha-3">
          <input type="hidden" name="empresa" value={id} /><input type="hidden" name="voltar" value={aqui} />
          <div className={s.campos}>
            <label className="campo"><span>Tipo</span>
              <select name="tipo" className="entrada" defaultValue="EB">{Object.entries(TIPOS).map(([k, n]) => <option key={k} value={k}>{n}</option>)}</select>
            </label>
            <label className="campo"><span>Descrição</span><input name="descricao" className="entrada" maxLength={200} required placeholder="Extrato da conta à ordem" /></label>
            <label className="campo"><span>Banco (opcional)</span><input name="banco" className="entrada" maxLength={80} /></label>
          </div>
          <div className={s.linhaBotoes}><Submeter className="btn btn-secundario btn-sm">Acrescentar</Submeter></div>
        </form>
        {(recorrentes ?? []).length > 0 && (
          <form action={gerarRecorrentes} className={s.acoes}>
            <input type="hidden" name="voltar" value={aqui} />
            <input type="month" name="periodo" className="entrada" style={{ inlineSize: 'auto' }} defaultValue={mesAnterior} aria-label="Mês" />
            <Submeter className="btn btn-secundario btn-sm" aDecorrer="A criar…">Criar agora</Submeter>
          </form>
        )}
      </section>
    </div>
  );
}
