import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { estadoCredenciaisEmpresa } from '@/lib/cegid-empresas';
import { uuid } from '@/lib/data';
import {
  apagarCegid, apagarPrazo, conferirMes, criarPrazo, definirDataCorte, guardarCegidEmpresa,
  marcarTodosVistos, responderMensagem, reverDocumento, testarCegid,
} from '@/lib/empresas-portal-actions';
import c from '../empresas.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Empresa' };

const PORTAL = (process.env.NEXT_PUBLIC_EMPRESAS_URL || 'https://portal.rr-contabilidade.com').replace(/\/$/, '');
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const CATEGORIAS: Record<string, string> = { vendas: 'Vendas', compras: 'Compras e despesas', bancos: 'Bancos', pessoal: 'Pessoal', outros: 'Outros' };
const TIPOS: Record<string, string> = {
  data_corte: 'Data de corte', documento: 'Documento', documento_atrasado: 'Documento fora do prazo', documento_eliminado: 'Documento apagado',
  documento_devolvido: 'Devolvido', mes_completo: 'Mês entregue', mes_conferido: 'Mês conferido', balancete: 'Balancete consultado',
  balancete_pdf: 'Balancete PDF', balancete_xlsx: 'Balancete Excel', extrato: 'Extrato', saldos: 'Saldos', clientes: 'Clientes',
  fornecedores: 'Fornecedores', bancos: 'Bancos',
};

const lisboa = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('pt-PT', { timeZone: 'Europe/Lisbon', ...o });
const dataHora = (iso: string | null) => (iso ? lisboa({ day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso)) : '—');
const data = (iso: string | null) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : '—');
const nomeMes = (mes: string) => { const [a, m] = mes.split('-').map(Number); return `${MESES[m - 1]} de ${a}`; };
const tamanho = (b: number) => (b < 1024 * 1024 ? `${Math.max(1, Math.round(b / 1024))} KB` : `${(b / 1024 / 1024).toFixed(1).replace('.', ',')} MB`);

function meses(quantos = 13) {
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date());
  const [a, m] = hoje.split('-').map(Number);
  return Array.from({ length: quantos }, (_, i) => {
    const d = new Date(Date.UTC(a, m - 1 - i, 1));
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
  });
}

type Documento = { id: string; categoria: string; nome: string; tamanho: number; tamanho_original: number | null; estado: string; atrasado: boolean; resposta: string | null; nota: string | null; enviado_em: string };
type Ligacao = { active: boolean; profile: { email: string; full_name: string | null } | null };

export default async function Empresa({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ erro?: string; mensagem?: string; mes?: string }>;
}) {
  const [{ id }, pedido] = await Promise.all([params, searchParams]);
  if (!uuid(id)) notFound();
  const { client } = await session();
  const { data: empresa } = await client.from('companies')
    .select('id,name,nif,active,data_corte,data_corte_em,company_users(active,profile:profiles(email,full_name))').eq('id', id).maybeSingle();
  if (!empresa) notFound();

  const lista = meses();
  const dia = Number(new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon', day: '2-digit' }).format(new Date()));
  const mes = lista.includes(pedido.mes || '') ? pedido.mes! : dia <= 10 ? lista[1] : lista[0];
  const hoje = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date());

  const [docs, estadoMes, mensagens, prazos, atividade, cortes, cegid] = await Promise.all([
    client.from('empresa_documentos').select('id,categoria,nome,tamanho,tamanho_original,estado,atrasado,resposta,nota,enviado_em')
      .eq('company_id', id).eq('mes', `${mes}-01`).neq('estado', 'pendente').order('enviado_em', { ascending: false }),
    client.from('empresa_meses').select('completo_em,conferido_em,nota').eq('company_id', id).eq('mes', `${mes}-01`).maybeSingle(),
    client.from('empresa_mensagens').select('id,corpo,do_gabinete,criado_em,lida_em').eq('company_id', id).order('criado_em', { ascending: false }).limit(60),
    client.from('empresa_prazos').select('id,titulo,data,descricao,company_id').or(`company_id.eq.${id},company_id.is.null`).gte('data', hoje).order('data').limit(30),
    client.from('empresa_atividade').select('id,tipo,detalhe,criado_em').eq('company_id', id).order('criado_em', { ascending: false }).limit(25),
    client.from('empresa_cortes').select('id,data_corte,nota,definido_em').eq('company_id', id).order('definido_em', { ascending: false }).limit(5),
    estadoCredenciaisEmpresa(id),
  ]);
  const documentos = (docs.data ?? []) as Documento[];
  const conversa = [...(mensagens.data ?? [])].reverse();
  const porLer = conversa.filter((m) => !m.do_gabinete && !m.lida_em).length;
  const ligacoes = ((empresa.company_users ?? []) as unknown as Ligacao[]);
  const porVer = documentos.filter((d) => d.estado === 'recebido').length;

  return (
    <>
      <Avisos erro={pedido.erro} mensagem={pedido.mensagem} />

      <div className={c.topo}>
        <div>
          <h2>{empresa.name}</h2>
          <p>NIF {empresa.nif} · {ligacoes.filter((l) => l.active).map((l) => l.profile?.email).filter(Boolean).join(', ') || 'sem utilizadores ativos'}</p>
        </div>
        <div className={c.acoes}>
          <Link className="btn btn-secundario btn-sm" href="/empresas">Todas as empresas</Link>
          <a className="btn btn-sm" href={`${PORTAL}/app/${id}`} target="_blank" rel="noopener">Ver no portal</a>
        </div>
      </div>

      <div className={c.duas}>
        <div className={c.caixa}>
          <h3>Data de corte</h3>
          <p className="pequeno">
            {empresa.data_corte
              ? <>A contabilidade está fechada até <strong>{data(empresa.data_corte)}</strong>. O cliente só tira saldos e balancetes até aqui (balancetes até ao último mês completo).</>
              : 'Sem data de corte: o cliente não consegue tirar saldos nem balancetes.'}
          </p>
          <form action={definirDataCorte} className="pilha pilha-3">
            <input type="hidden" name="empresa" value={id} />
            <div className={c.campos}>
              <label className="campo"><span>Fechada até</span>
                <input name="data_corte" type="date" className="entrada" max={hoje} defaultValue={empresa.data_corte ?? ''} />
              </label>
              <label className="campo"><span>Nota (opcional)</span>
                <input name="nota" className="entrada" maxLength={500} placeholder="Ex.: setembro revisto e reconciliado" />
              </label>
            </div>
            <div className={c.acoes}>
              <Submeter className="btn btn-sm" aDecorrer="A guardar…">Guardar data de corte</Submeter>
            </div>
            <small className="pequeno suave">Para retirar a data de corte, apague o campo e guarde.</small>
          </form>
          {cortes.data?.length ? (
            <ul className={c.lista}>
              {cortes.data.map((x) => <li key={x.id}><div>{x.data_corte ? `Fechada até ${data(x.data_corte)}` : 'Retirada'}{x.nota && <small>{x.nota}</small>}</div><time>{dataHora(x.definido_em)}</time></li>)}
            </ul>
          ) : null}
        </div>

        <div className={c.caixa}>
          <h3>Cegid Business desta empresa</h3>
          <p className="pequeno">
            {cegid.guardadas
              ? cegid.formatoAntigo
                ? 'Há uma credencial guardada no formato antigo (um só campo). Grave de novo o identificador e o segredo.'
                : <>Ligada com o identificador <strong>{cegid.identificador}</strong> · atualizada a {dataHora(cegid.atualizado)}.</>
              : 'Ainda sem ligação: o cliente vê a mensagem de que a empresa ainda não está ligada ao Cegid.'}
          </p>
          <form action={guardarCegidEmpresa} className="pilha pilha-3">
            <input type="hidden" name="empresa" value={id} />
            <div className={c.campos}>
              <label className="campo"><span>Identificador (client_id)</span><input name="identificador" className="entrada" required maxLength={500} autoComplete="off" /></label>
              <label className="campo"><span>Segredo (client_secret)</span><input name="segredo" type="password" className="entrada" required maxLength={2000} autoComplete="new-password" /></label>
            </div>
            <details>
              <summary className="pequeno suave">Endereços do Cegid (só se forem diferentes dos habituais)</summary>
              <div className={c.campos} style={{ marginBlockStart: 'var(--e-3)' }}>
                <label className="campo"><span>OAUTH_URL</span><input name="oauth_url" className="entrada" placeholder="https://app2.business-pt.cegid.cloud/oauth" /></label>
                <label className="campo"><span>API_URL</span><input name="api_url" className="entrada" placeholder="https://api2.business-pt.cegid.cloud" /></label>
              </div>
            </details>
            <small className="pequeno suave">No Cegid da empresa: Empresa → Configurações → Dados API. Fica cifrado; este ecrã nunca mostra o segredo.</small>
            <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A guardar e testar…">Guardar e testar</Submeter></div>
          </form>
          {cegid.guardadas && (
            <div className={c.acoes}>
              <form action={testarCegid}><input type="hidden" name="empresa" value={id} /><Submeter className="btn btn-secundario btn-sm" aDecorrer="A testar…">Testar ligação</Submeter></form>
              <form action={apagarCegid}><input type="hidden" name="empresa" value={id} /><Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Apagar credenciais</Submeter></form>
            </div>
          )}
        </div>
      </div>

      <Secao titulo={`Documentos de ${nomeMes(mes)}`} nota={`Prazo: dia 10 do mês seguinte · ${documentos.length} enviados · ${porVer} por ver`}>
        <nav className={c.meses} aria-label="Mês">
          {lista.map((m) => <Link key={m} className={c.mes} aria-current={m === mes} href={`/empresas/${id}?mes=${m}`}>{nomeMes(m)}</Link>)}
        </nav>
        <div className={c.duas}>
          <div className={c.caixa}>
            {documentos.length === 0 ? <p className="pequeno suave">Sem documentos deste mês.</p> : documentos.map((d) => (
              <div key={d.id} className={c.documento}>
                <div>
                  <a href={`/empresas/${id}/documento/${d.id}`} target="_blank" rel="noopener">{d.nome}</a>
                  <small>{CATEGORIAS[d.categoria] ?? d.categoria} · {tamanho(d.tamanho)}{d.tamanho_original && d.tamanho_original > d.tamanho ? ` (original ${tamanho(d.tamanho_original)})` : ''} · {dataHora(d.enviado_em)}{d.nota ? ` · «${d.nota}»` : ''}</small>
                </div>
                <div className={c.estado}>
                  {d.atrasado && <span className="etiqueta etiqueta-atencao">Fora do prazo</span>}
                  <span className={`etiqueta ${d.estado === 'visto' ? 'etiqueta-positivo' : d.estado === 'devolvido' ? 'etiqueta-critico' : 'etiqueta-acao'}`}>
                    {d.estado === 'visto' ? 'Visto' : d.estado === 'devolvido' ? 'Devolvido' : 'Por ver'}
                  </span>
                  {d.estado !== 'visto' && (
                    <form action={reverDocumento}>
                      <input type="hidden" name="empresa" value={id} /><input type="hidden" name="documento" value={d.id} /><input type="hidden" name="mes" value={mes} /><input type="hidden" name="estado" value="visto" />
                      <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">Visto</Submeter>
                    </form>
                  )}
                  {d.estado !== 'recebido' && (
                    <form action={reverDocumento}>
                      <input type="hidden" name="empresa" value={id} /><input type="hidden" name="documento" value={d.id} /><input type="hidden" name="mes" value={mes} /><input type="hidden" name="estado" value="recebido" />
                      <Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Repor</Submeter>
                    </form>
                  )}
                </div>
                {d.estado === 'devolvido' && d.resposta && <small style={{ gridColumn: '1 / -1' }}>Motivo: {d.resposta}</small>}
                {d.estado !== 'devolvido' && (
                  <form action={reverDocumento} className={c.devolver}>
                    <input type="hidden" name="empresa" value={id} /><input type="hidden" name="documento" value={d.id} /><input type="hidden" name="mes" value={mes} /><input type="hidden" name="estado" value="devolvido" />
                    <input name="resposta" className="entrada" maxLength={1000} placeholder="Devolver ao cliente: motivo (ilegível, falta página…)" required />
                    <Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Devolver</Submeter>
                  </form>
                )}
              </div>
            ))}
            {porVer > 1 && (
              <form action={marcarTodosVistos}>
                <input type="hidden" name="empresa" value={id} /><input type="hidden" name="mes" value={mes} />
                <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">Marcar os {porVer} como vistos</Submeter>
              </form>
            )}
          </div>
          <div className={c.caixa}>
            <h3>Conferência do mês</h3>
            <p className="pequeno">
              {estadoMes.data?.completo_em ? `O cliente deu o mês como completo a ${dataHora(estadoMes.data.completo_em)}.` : 'O cliente ainda não deu o mês como completo.'}
              {estadoMes.data?.conferido_em ? ` Conferido a ${dataHora(estadoMes.data.conferido_em)}.` : ''}
            </p>
            <form action={conferirMes} className="pilha pilha-3">
              <input type="hidden" name="empresa" value={id} /><input type="hidden" name="mes" value={mes} />
              <input type="hidden" name="conferido" value={estadoMes.data?.conferido_em ? 'false' : 'true'} />
              {!estadoMes.data?.conferido_em && (
                <label className="campo"><span>Nota para o cliente (opcional)</span><input name="nota" className="entrada" maxLength={1000} defaultValue={estadoMes.data?.nota ?? ''} /></label>
              )}
              <div className={c.acoes}>
                <Submeter className={estadoMes.data?.conferido_em ? 'btn btn-discreto btn-sm' : 'btn btn-sm'} aDecorrer="…">
                  {estadoMes.data?.conferido_em ? 'Anular conferência' : 'Dar o mês como conferido'}
                </Submeter>
              </div>
            </form>
          </div>
        </div>
      </Secao>

      <div className={c.duas}>
        <section className={c.caixa} id="mensagens">
          <h3>Mensagens {porLer ? `· ${porLer} por ler` : ''}</h3>
          <div className={c.conversa}>
            {conversa.length === 0 ? <p className="pequeno suave">Sem mensagens.</p> : conversa.map((m) => (
              <div key={m.id} className={c.balao} data-gabinete={m.do_gabinete}>
                <p>{m.corpo}</p>
                <time>{m.do_gabinete ? 'Gabinete' : 'Cliente'} · {dataHora(m.criado_em)}{!m.do_gabinete && !m.lida_em ? ' · nova' : ''}</time>
              </div>
            ))}
          </div>
          <form action={responderMensagem} className="pilha pilha-3">
            <input type="hidden" name="empresa" value={id} />
            <label className="campo"><span>Responder</span><textarea name="corpo" className="entrada" required maxLength={5000} rows={3} /></label>
            <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A enviar…">Enviar e avisar por email</Submeter></div>
          </form>
        </section>

        <section className={c.caixa} id="prazos">
          <h3>Prazos no portal</h3>
          {prazos.data?.length ? (
            <ul className={c.lista}>
              {prazos.data.map((x) => (
                <li key={x.id}>
                  <div>{x.titulo}<small>{data(x.data)}{x.company_id ? '' : ' · todas as empresas'}{x.descricao ? ` · ${x.descricao}` : ''}</small></div>
                  <form action={apagarPrazo}><input type="hidden" name="empresa" value={id} /><input type="hidden" name="prazo" value={x.id} /><Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Apagar</Submeter></form>
                </li>
              ))}
            </ul>
          ) : <p className="pequeno suave">Sem prazos futuros. O dos documentos (dia 10) aparece sozinho.</p>}
          <form action={criarPrazo} className="pilha pilha-3">
            <input type="hidden" name="empresa" value={id} />
            <div className={c.campos}>
              <label className="campo"><span>Título</span><input name="titulo" className="entrada" required maxLength={200} placeholder="Ex.: Pagamento do IVA do 3.º trimestre" /></label>
              <label className="campo"><span>Data</span><input name="data" type="date" className="entrada" required min={hoje} /></label>
            </div>
            <label className="campo"><span>Descrição (opcional)</span><input name="descricao" className="entrada" maxLength={1000} placeholder="Valor, referência, o que o cliente tem de fazer" /></label>
            <label className="caixa"><input type="checkbox" name="todas" /> <span className="pequeno">Mostrar a todas as empresas</span></label>
            <div className={c.acoes}><Submeter className="btn btn-secundario btn-sm" aDecorrer="A criar…">Criar prazo</Submeter></div>
          </form>
        </section>
      </div>

      <Secao titulo="Atividade recente" nota="Inclui cada balancete descarregado, com a referência impressa no ficheiro.">
        <div className={c.caixa}>
          {atividade.data?.length ? (
            <ul className={c.lista}>
              {atividade.data.map((a) => <li key={a.id}><div>{TIPOS[a.tipo] ?? a.tipo}<small>{a.detalhe}</small></div><time>{dataHora(a.criado_em)}</time></li>)}
            </ul>
          ) : <p className="pequeno suave">Sem atividade.</p>}
        </div>
      </Secao>
    </>
  );
}
