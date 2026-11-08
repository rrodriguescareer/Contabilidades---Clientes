import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { IniciarProcesso, Numero, Progresso, SeletorPeriodo } from '@/components/secretaria/comum';
import { PRAZOS, dataHoraPt, dataPt, lerPeriodo, limiteSugerido, linhaDocumento, respostaTexto, type ClienteResumo, type PendenciaAberta } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Clientes · Secretária' };

const FILTROS: { chave: string; nome: string; teste: (c: ClienteResumo) => boolean }[] = [
  { chave: '', nome: 'Todos', teste: () => true },
  { chave: 'pendencias', nome: 'Com pendências', teste: (c) => c.em_falta > 0 },
  { chave: 'sem_resposta', nome: 'Sem resposta', teste: (c) => c.resposta === 'sem_resposta' },
  { chave: 'criticos', nome: 'Críticos', teste: (c) => c.prazo === 'em_risco' },
  { chave: 'atraso', nome: 'Em atraso', teste: (c) => c.prazo === 'fora' },
  { chave: 'resolvidos', nome: 'Resolvidos', teste: (c) => c.total > 0 && c.em_falta === 0 },
  { chave: 'aprovar', nome: 'Por aprovar', teste: (c) => c.por_aprovar > 0 },
];

type Procura = { modo?: string; p?: string; f?: string; q?: string; c?: string; erro?: string; mensagem?: string };

export default async function ClientesSecretaria({ searchParams }: { searchParams: Promise<Procura> }) {
  const { client } = await ownerSession();
  const pedido = await searchParams;
  const periodo = lerPeriodo(pedido.modo, pedido.p);
  const [{ data: lista }, { data: definicoes }] = await Promise.all([
    client.rpc('secretaria_clientes_resumo', { desde: periodo.desde, ate: periodo.ate }),
    client.from('secretaria_definicoes').select('aprovar,dia_limite').maybeSingle(),
  ]);
  const clientes = (lista ?? []) as ClienteResumo[];

  const filtro = FILTROS.find((f) => f.chave === pedido.f) ?? FILTROS[0];
  const q = (pedido.q || '').trim().toLowerCase();
  const visiveis = clientes.filter((c) => filtro.teste(c) && (!q || c.nome.toLowerCase().includes(q) || c.nif.includes(q)));
  const escolhido = clientes.find((c) => c.id === pedido.c) ?? null;

  const total = clientes.reduce((t, c) => t + c.total, 0);
  const recebidas = clientes.reduce((t, c) => t + c.recebidas, 0);
  const emFalta = clientes.reduce((t, c) => t + c.em_falta, 0);

  const url = (extra: Record<string, string | undefined>) => {
    const u = new URLSearchParams();
    for (const [k, v] of Object.entries({ modo: pedido.modo, p: pedido.p, f: pedido.f, q: pedido.q, c: pedido.c, ...extra })) if (v) u.set(k, v);
    const t = u.toString();
    return t ? `/secretaria/clientes?${t}` : '/secretaria/clientes';
  };

  const [{ data: faltam }, { data: periodosAbertos }] = escolhido
    ? await Promise.all([
        client.from('secretaria_pendencias').select('id,periodo,tipo,descricao,numero,data_documento,valor_cents,banco')
          .eq('company_id', escolhido.id).eq('estado', 'pendente').gte('periodo', periodo.desde).lte('periodo', periodo.ate)
          .order('data_documento', { ascending: true, nullsFirst: false }).limit(5),
        client.from('secretaria_pendencias').select('periodo').eq('company_id', escolhido.id).eq('estado', 'pendente').limit(200),
      ])
    : [{ data: null }, { data: null }];

  return (
    <div className={s.pagina}>
      <Avisos erro={pedido.erro} mensagem={pedido.mensagem} />
      <div className={s.intro}>
        <p>O estado da entrega de documentos de cada cliente, e o que precisa de ser pedido.</p>
      </div>

      <div className={s.numeros}>
        <Numero rotulo="Clientes ativos" valor={clientes.length} />
        <Numero rotulo="Documentos em falta" valor={emFalta} tom={emFalta ? 'atencao' : undefined} />
        <Numero rotulo="Documentação entregue" valor={total ? `${Math.round((recebidas / total) * 100)}%` : '—'} nota={total ? `${recebidas} de ${total}` : 'Sem pendências neste período'} />
      </div>

      <div className={s.barraFerramentas}>
        <SeletorPeriodo periodo={periodo} caminho="/secretaria/clientes" manter={{ f: pedido.f, q: pedido.q }} />
        <form className={s.procura} action="/secretaria/clientes">
          {pedido.modo && <input type="hidden" name="modo" value={pedido.modo} />}
          {pedido.p && <input type="hidden" name="p" value={pedido.p} />}
          {pedido.f && <input type="hidden" name="f" value={pedido.f} />}
          <input type="search" name="q" className="entrada" placeholder="Procurar cliente ou NIF…" aria-label="Procurar cliente ou NIF" defaultValue={pedido.q} />
        </form>
      </div>

      <nav className={s.chips} aria-label="Filtrar clientes">
        {FILTROS.map((f) => (
          <Link prefetch={false} key={f.chave} className={s.chip} href={url({ f: f.chave || undefined, c: undefined })} aria-current={filtro.chave === f.chave ? 'true' : undefined}>
            {f.nome} <b>{clientes.filter(f.teste).length}</b>
          </Link>
        ))}
      </nav>

      <div className={`${s.duas} ${s.lateralPrimeiro}`}>
        <section className="pilha pilha-3" aria-label="Entrega por cliente">
          {visiveis.length === 0 ? (
            <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Nenhum cliente neste filtro</strong><span>Experimente outro filtro ou período.</span></div>
          ) : (
            <div className={s.envolve}>
              <table className={s.tabela}>
                <thead><tr><th>Cliente</th><th>Documentação</th><th>Prazo</th><th>Resposta</th></tr></thead>
                <tbody>
                  {visiveis.map((c) => (
                    <tr key={c.id} aria-current={escolhido?.id === c.id ? 'true' : undefined}>
                      <td data-rotulo="">
                        <Link prefetch={false} className={s.nome} href={url({ c: c.id })}>{c.nome}</Link>
                        <span className={s.segundo}>NIF {c.nif}{c.periodicidade === 'isento' ? ' · Isento' : ''}</span>
                      </td>
                      <td data-rotulo="Documentação"><Progresso parte={c.recebidas} total={c.total} /></td>
                      <td data-rotulo="Prazo">{c.prazo ? <span className={PRAZOS[c.prazo].classe}>{PRAZOS[c.prazo].nome}</span> : '—'}</td>
                      <td data-rotulo="Resposta" className={s.nowrap}>{respostaTexto(c)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <aside className={s.bloco} aria-label="Cliente escolhido">
          {!escolhido ? (
            <div className={s.vazioPequeno}><strong>Escolha um cliente</strong><span>Para ver o que falta e agir daqui.</span></div>
          ) : (
            <>
              <div className={s.blocoTitulo}>
                <h3>{escolhido.nome}</h3>
                <p>NIF {escolhido.nif}</p>
              </div>
              <dl className={s.emailDados}>
                <dt>Em falta</dt><dd>{escolhido.em_falta}</dd>
                <dt>Último contacto</dt><dd>{dataHoraPt(escolhido.ultimo_contacto)}</dd>
                {escolhido.processo && <><dt>Dia limite</dt><dd>{dataPt(escolhido.processo.dia_limite)}</dd></>}
                {escolhido.processo?.proximo_envio && <><dt>Próximo envio</dt><dd>{dataHoraPt(escolhido.processo.proximo_envio)}</dd></>}
                {escolhido.responsavel && <><dt>Responsável</dt><dd>{escolhido.responsavel}</dd></>}
              </dl>
              {(faltam ?? []).length > 0 && (
                <div className="pilha pilha-2">
                  <strong className="pequeno">Ainda por receber</strong>
                  <ul className="pequeno suave" style={{ paddingInlineStart: '1.1rem' }}>
                    {(faltam as PendenciaAberta[]).map((x) => <li key={x.id}>{linhaDocumento(x)}</li>)}
                  </ul>
                  {escolhido.em_falta > 5 && <span className="pequeno tenue">e mais {escolhido.em_falta - 5}.</span>}
                </div>
              )}
              {!escolhido.tem_contacto && <p className="aviso aviso-atencao pequeno">Falta um contacto principal para poder pedir documentos.</p>}
              <div className={s.acoes}>
                {!escolhido.processo && escolhido.em_falta_total > 0 && escolhido.tem_contacto && (
                  <IniciarProcesso empresa={escolhido.id} voltar={url({})} aprovar={definicoes?.aprovar ?? 'primeiro'}
                                   limite={limiteSugerido(definicoes?.dia_limite ?? 10, ((periodosAbertos ?? []) as { periodo: string }[]).map((x) => x.periodo.slice(0, 7)))} />
                )}
                <Link prefetch={false} className="btn btn-secundario btn-sm" href={`/secretaria/clientes/${escolhido.id}`}>Abrir ficha do cliente</Link>
              </div>
            </>
          )}
        </aside>
      </div>
    </div>
  );
}
