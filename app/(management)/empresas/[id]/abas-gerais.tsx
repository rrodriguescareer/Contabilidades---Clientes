import Link from 'next/link';
import { Submeter } from '@/components/forms';
import { estadoCredenciaisEmpresa } from '@/lib/cegid-empresas';
import {
  apagarCegid, apagarPrazo, conferirMes, criarPrazo, definirDataCorte, guardarCegidEmpresa,
  marcarTodosVistos, responderMensagem, reverDocumento, testarCegid,
} from '@/lib/empresas-portal-actions';
import { apagarAlerta, criarAlerta, definirInicio, definirMes, renovarCegid } from '@/lib/empresas-gestao-actions';
import { data, dataHora, nomeMes, tamanho, TIPOS_ATIVIDADE, type Contexto } from './comum';
import c from '../empresas.module.css';

const CATEGORIAS: Record<string, string> = { vendas: 'Vendas', compras: 'Compras e despesas', bancos: 'Bancos', pessoal: 'Pessoal', outros: 'Outros' };

/* ------------------------------------------------------------ resumo */

export async function AbaResumo({ client, id, hoje, empresa }: Contexto) {
  const [cortes, cegid] = await Promise.all([
    client.from('empresa_cortes').select('id,data_corte,nota,definido_em').eq('company_id', id).order('definido_em', { ascending: false }).limit(5),
    estadoCredenciaisEmpresa(id),
  ]);
  return (
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
            <label className="campo"><span>Fechada até</span><input name="data_corte" type="date" className="entrada" max={hoje} defaultValue={empresa.data_corte ?? ''} /></label>
            <label className="campo"><span>Nota (opcional)</span><input name="nota" className="entrada" maxLength={500} placeholder="Ex.: setembro revisto e reconciliado" /></label>
          </div>
          <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A guardar…">Guardar data de corte</Submeter></div>
          <small className="pequeno suave">Para retirar a data de corte, apague o campo e guarde.</small>
        </form>
        {cortes.data?.length ? (
          <ul className={c.lista}>
            {cortes.data.map((x) => <li key={x.id}><div>{x.data_corte ? `Fechada até ${data(x.data_corte)}` : 'Retirada'}{x.nota && <small>{x.nota}</small>}</div><time>{dataHora(x.definido_em)}</time></li>)}
          </ul>
        ) : null}
      </div>

      <div className={c.caixa}>
        <h3>Início do acompanhamento</h3>
        <p className="pequeno">
          {empresa.inicio ? <>O portal mostra a empresa a partir de <strong>{nomeMes(empresa.inicio.slice(0, 7))}</strong>: não há meses antes deste para enviar documentos.</> : 'Sem mês de início: o cliente pode enviar documentos dos últimos 24 meses.'}
        </p>
        <form action={definirInicio} className="pilha pilha-3">
          <input type="hidden" name="empresa" value={id} />
          <label className="campo"><span>Primeiro mês acompanhado</span><input name="inicio" type="month" className="entrada" defaultValue={empresa.inicio?.slice(0, 7) ?? ''} /></label>
          <div className={c.acoes}><Submeter className="btn btn-secundario btn-sm" aDecorrer="A guardar…">Guardar início</Submeter></div>
        </form>
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
            <form action={renovarCegid}><input type="hidden" name="empresa" value={id} /><Submeter className="btn btn-secundario btn-sm" aDecorrer="…">Voltar a ler do Cegid</Submeter></form>
            <form action={apagarCegid}><input type="hidden" name="empresa" value={id} /><Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Apagar credenciais</Submeter></form>
          </div>
        )}
        <small className="pequeno suave">O portal guarda o que lê do Cegid durante 30 dias (o período antes da data de corte não muda). Mudar a data de corte ou as credenciais renova tudo; «Voltar a ler» força-o já.</small>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------ documentos */

type Documento = { id: string; categoria: string; nome: string; tamanho: number; tamanho_original: number | null; estado: string; atrasado: boolean; resposta: string | null; nota: string | null; enviado_em: string };

export async function AbaDocumentos({ client, id, mes, meses, empresa }: Contexto) {
  const [docs, estadoMes] = await Promise.all([
    client.from('empresa_documentos').select('id,categoria,nome,tamanho,tamanho_original,estado,atrasado,resposta,nota,enviado_em')
      .eq('company_id', id).eq('mes', `${mes}-01`).neq('estado', 'pendente').order('enviado_em', { ascending: false }),
    client.from('empresa_meses').select('completo_em,conferido_em,nota,bloqueado,fechado_em').eq('company_id', id).eq('mes', `${mes}-01`).maybeSingle(),
  ]);
  const documentos = (docs.data ?? []) as Documento[];
  const porVer = documentos.filter((d) => d.estado === 'recebido').length;
  const m = estadoMes.data;
  const estado = m?.fechado_em ? 'fechado' : m?.bloqueado ? 'bloqueado' : 'aberto';
  const inicio = empresa.inicio?.slice(0, 7);
  return (
    <>
      <nav className={c.meses} aria-label="Mês">
        {meses.map((x) => (
          <Link key={x} className={c.mes} aria-current={x === mes} href={`/empresas/${id}?aba=documentos&mes=${x}`}
                style={inicio && x < inicio ? { opacity: .45 } : undefined}>{nomeMes(x)}</Link>
        ))}
      </nav>
      <div className={c.duas}>
        <div className={c.caixa}>
          <h3>Documentos de {nomeMes(mes)} · {documentos.length} enviados · {porVer} por ver</h3>
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
        <div className="pilha pilha-4">
          <div className={c.caixa}>
            <h3>Estado do mês</h3>
            <p className="pequeno">
              {estado === 'fechado' ? `Informação completa (fechado a ${dataHora(m!.fechado_em)}): o cliente já não envia documentos.`
                : estado === 'bloqueado' ? 'Envio bloqueado: o cliente não consegue enviar documentos deste mês.'
                : 'Aberto: o cliente pode enviar documentos.'}
            </p>
            <div className={c.acoes}>
              {(['aberto', 'bloqueado', 'fechado'] as const).filter((x) => x !== estado).map((x) => (
                <form key={x} action={definirMes}>
                  <input type="hidden" name="empresa" value={id} /><input type="hidden" name="mes" value={mes} /><input type="hidden" name="estado" value={x} />
                  <Submeter className={x === 'fechado' ? 'btn btn-sm' : 'btn btn-secundario btn-sm'} aDecorrer="…">
                    {x === 'fechado' ? 'Fechar: informação completa' : x === 'bloqueado' ? 'Bloquear envio' : 'Reabrir'}
                  </Submeter>
                </form>
              ))}
            </div>
          </div>
          <div className={c.caixa}>
            <h3>Conferência</h3>
            <p className="pequeno">
              {m?.completo_em ? `O cliente deu o mês como completo a ${dataHora(m.completo_em)}.` : 'O cliente ainda não deu o mês como completo.'}
              {m?.conferido_em ? ` Conferido a ${dataHora(m.conferido_em)}.` : ''}
            </p>
            <form action={conferirMes} className="pilha pilha-3">
              <input type="hidden" name="empresa" value={id} /><input type="hidden" name="mes" value={mes} />
              <input type="hidden" name="conferido" value={m?.conferido_em ? 'false' : 'true'} />
              {!m?.conferido_em && <label className="campo"><span>Nota para o cliente (opcional)</span><input name="nota" className="entrada" maxLength={1000} defaultValue={m?.nota ?? ''} /></label>}
              <div className={c.acoes}>
                <Submeter className={m?.conferido_em ? 'btn btn-discreto btn-sm' : 'btn btn-secundario btn-sm'} aDecorrer="…">
                  {m?.conferido_em ? 'Anular conferência' : 'Dar o mês como conferido'}
                </Submeter>
              </div>
            </form>
          </div>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------ mensagens e prazos */

export async function AbaMensagens({ client, id, hoje }: Contexto) {
  const [mensagens, prazos] = await Promise.all([
    client.from('empresa_mensagens').select('id,corpo,do_gabinete,criado_em,lida_em').eq('company_id', id).order('criado_em', { ascending: false }).limit(60),
    client.from('empresa_prazos').select('id,titulo,data,descricao,company_id').or(`company_id.eq.${id},company_id.is.null`).gte('data', hoje).order('data').limit(30),
  ]);
  const conversa = [...(mensagens.data ?? [])].reverse();
  const porLer = conversa.filter((m) => !m.do_gabinete && !m.lida_em).length;
  return (
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
            <label className="campo"><span>Título</span><input name="titulo" className="entrada" required maxLength={200} placeholder="Ex.: Declaração periódica do IVA" /></label>
            <label className="campo"><span>Data</span><input name="data" type="date" className="entrada" required min={hoje} /></label>
          </div>
          <label className="campo"><span>Descrição (opcional)</span><input name="descricao" className="entrada" maxLength={1000} /></label>
          <label className="caixa"><input type="checkbox" name="todas" /> <span className="pequeno">Mostrar a todas as empresas</span></label>
          <div className={c.acoes}><Submeter className="btn btn-secundario btn-sm" aDecorrer="A criar…">Criar prazo</Submeter></div>
        </form>
      </section>
    </div>
  );
}

/* ------------------------------------------------------------ alertas */

export async function AbaAlertas({ client, id }: Contexto) {
  const [{ data: alertas }, { data: lidos }] = await Promise.all([
    client.from('empresa_alertas').select('id,titulo,corpo,nivel,expira_em,criado_em,company_id').or(`company_id.eq.${id},company_id.is.null`).order('criado_em', { ascending: false }).limit(40),
    client.from('empresa_alertas_lidos').select('alerta_id,user_id,lido_em'),
  ]);
  return (
    <div className={c.duas}>
      <section className={c.caixa}>
        <h3>Novo alerta no portal</h3>
        <p className="pequeno suave">Aparece no topo de todos os ecrãs da empresa até o cliente o marcar como lido.</p>
        <form action={criarAlerta} className="pilha pilha-3">
          <input type="hidden" name="empresa" value={id} />
          <label className="campo"><span>Título</span><input name="titulo" className="entrada" required maxLength={200} placeholder="Ex.: Falta o extrato do Millennium de setembro" /></label>
          <label className="campo"><span>Texto (opcional)</span><textarea name="corpo" className="entrada" rows={3} maxLength={2000} /></label>
          <div className={c.campos}>
            <label className="campo"><span>Nível</span>
              <select name="nivel" className="entrada" defaultValue="info"><option value="info">Informação</option><option value="aviso">Aviso</option><option value="urgente">Urgente</option></select>
            </label>
            <label className="campo"><span>Mostrar até (opcional)</span><input name="expira" type="date" className="entrada" /></label>
          </div>
          <label className="caixa"><input type="checkbox" name="email" defaultChecked /> <span className="pequeno">Avisar também por email</span></label>
          <label className="caixa"><input type="checkbox" name="todas" /> <span className="pequeno">Para todas as empresas (sem email)</span></label>
          <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A publicar…">Publicar alerta</Submeter></div>
        </form>
      </section>
      <section className={c.caixa}>
        <h3>Alertas publicados</h3>
        {alertas?.length ? (
          <ul className={c.lista}>
            {alertas.map((a) => {
              const leituras = (lidos ?? []).filter((l) => l.alerta_id === a.id);
              return (
                <li key={a.id}>
                  <div>
                    <strong>{a.titulo}</strong>
                    <small>
                      {a.nivel === 'urgente' ? 'Urgente' : a.nivel === 'aviso' ? 'Aviso' : 'Informação'} · {dataHora(a.criado_em)}
                      {a.company_id ? '' : ' · todas as empresas'}{a.expira_em ? ` · até ${data(a.expira_em)}` : ''}
                      {' · '}{leituras.length ? `lido por ${leituras.length} pessoa(s), a última a ${dataHora(leituras[leituras.length - 1].lido_em)}` : 'ainda não lido'}
                    </small>
                  </div>
                  <form action={apagarAlerta}><input type="hidden" name="empresa" value={id} /><input type="hidden" name="alerta" value={a.id} /><Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Apagar</Submeter></form>
                </li>
              );
            })}
          </ul>
        ) : <p className="pequeno suave">Sem alertas.</p>}
      </section>
    </div>
  );
}

/* ------------------------------------------------------------ atividade */

export async function AbaAtividade({ client, id }: Contexto) {
  const { data: atividade } = await client.from('empresa_atividade').select('id,tipo,detalhe,criado_em,ip').eq('company_id', id).order('criado_em', { ascending: false }).limit(150);
  return (
    <div className={c.caixa}>
      <h3>Atividade · inclui cada documento gerado, com a referência impressa no ficheiro</h3>
      {atividade?.length ? (
        <ul className={c.lista}>
          {atividade.map((a) => <li key={a.id}><div>{TIPOS_ATIVIDADE[a.tipo] ?? a.tipo}<small>{a.detalhe}{a.ip ? ` · ${a.ip}` : ''}</small></div><time>{dataHora(a.criado_em)}</time></li>)}
        </ul>
      ) : <p className="pequeno suave">Sem atividade.</p>}
    </div>
  );
}
