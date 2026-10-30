import { Submeter } from '@/components/forms';
import { CAMPOS, rotuloDoCampo, valorLegivel } from '@/lib/empresa-ficha';
import { ESTADOS_PESSOAL, rotuloPessoal, TIPOS_PESSOAL } from '@/lib/empresa-pessoal';
import {
  apagarImpostoGestao, enviarLogotipoGestao, guardarFichaGestao, guardarImpostoGestao, marcarImpostoGestao,
  tratarPessoalGestao,
} from '@/lib/empresas-gestao-actions';
import { PublicarRecibos } from './publicar-recibos';
import { data, dataHora, euros, mesesRecentes, nomeMes, type Contexto } from './comum';
import c from '../empresas.module.css';

const GRUPOS = ['Identificação', 'Fiscalidade', 'Morada', 'Segurança Social e banco', 'Contactos'] as const;
const TIPOS_IMPOSTO: Record<string, string> = { IRC: 'IRC', IVA: 'IVA', IRS: 'IRS (retenções)', SS: 'Segurança Social', OUTROS: 'Outros' };

type Ficheiro = { id: string; ref_id: string; nome: string; contexto: string };

/* ------------------------------------------------------------ ficha */

export async function AbaFicha({ client, id, empresa }: Contexto) {
  const [{ data: ficha }, { data: historico }] = await Promise.all([
    client.from('empresa_fichas').select('*').eq('company_id', id).maybeSingle(),
    client.from('empresa_ficha_historico').select('id,campo,antes,depois,origem,alterado_em').eq('company_id', id).order('alterado_em', { ascending: false }).limit(80),
  ]);
  const valores: Record<string, unknown> = { ...(ficha ?? {}), nome: empresa.name, nif: empresa.nif };
  return (
    <div className={c.duas}>
      <form action={guardarFichaGestao} className={c.caixa}>
        <input type="hidden" name="empresa" value={id} />
        {GRUPOS.map((g) => (
          <div key={g} className="pilha pilha-3">
            <h3>{g}</h3>
            <div className={c.campos}>
              {CAMPOS.filter((x) => x.grupo === g).map((x) => {
                const v = valores[x.nome];
                if (x.tipo === 'sim') return <label key={x.nome} className="caixa"><input type="checkbox" name={x.nome} defaultChecked={Boolean(v)} /> <span className="pequeno">{x.rotulo}</span></label>;
                return (
                  <label key={x.nome} className="campo" style={x.tipo === 'area' ? { gridColumn: '1 / -1' } : undefined}>
                    <span>{x.rotulo}{x.obrigatorio ? ' *' : ''}</span>
                    {x.tipo === 'escolha' ? (
                      <select name={x.nome} className="entrada" defaultValue={String(v ?? '')}>
                        <option value="">—</option>
                        {(Array.isArray(x.opcoes) ? x.opcoes.map((o) => [o, o]) : Object.entries(x.opcoes ?? {})).map(([valor, nome]) => <option key={valor} value={valor}>{nome}</option>)}
                      </select>
                    ) : x.tipo === 'area' ? (
                      <textarea name={x.nome} className="entrada" rows={3} maxLength={x.max} defaultValue={String(v ?? '')} />
                    ) : (
                      <input name={x.nome} className="entrada" maxLength={x.max} required={x.obrigatorio} defaultValue={v == null ? '' : String(v)}
                             type={x.tipo === 'email' ? 'email' : x.tipo === 'telefone' ? 'tel' : 'text'} />
                    )}
                    {x.ajuda && <small>{x.ajuda}</small>}
                  </label>
                );
              })}
            </div>
          </div>
        ))}
        <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A guardar…">Guardar ficha</Submeter></div>
      </form>
      <div className="pilha pilha-4">
        <div className={c.caixa}>
          <h3>Logótipo</h3>
          <p className="pequeno">{empresa.logotipo_caminho ? 'A empresa tem logótipo: aparece no portal e nos documentos gerados.' : 'Sem logótipo.'} No portal, o cliente pode enviar qualquer imagem (é otimizada); aqui, PNG ou WebP até 500 KB.</p>
          <form action={enviarLogotipoGestao} className="pilha pilha-3">
            <input type="hidden" name="empresa" value={id} />
            <input type="file" name="logotipo" accept="image/png,image/webp" required />
            <div className={c.acoes}><Submeter className="btn btn-secundario btn-sm" aDecorrer="A guardar…">Guardar logótipo</Submeter></div>
          </form>
        </div>
        <div className={c.caixa}>
          <h3>Histórico de alterações</h3>
          {historico?.length ? (
            <ul className={c.lista}>
              {historico.map((h) => (
                <li key={h.id}>
                  <div>{rotuloDoCampo(h.campo)}<small>{valorLegivel(h.campo, h.antes)} → {valorLegivel(h.campo, h.depois)} · {h.origem === 'gestao' ? 'gabinete' : 'cliente, no portal'}</small></div>
                  <time>{dataHora(h.alterado_em)}</time>
                </li>
              ))}
            </ul>
          ) : <p className="pequeno suave">Sem alterações.</p>}
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------ pessoal */

type Pedido = { id: string; tipo: string; trabalhador: string; dados: Record<string, string>; estado: string; resposta: string | null; criado_em: string };

export async function AbaPessoal({ client, id }: Contexto) {
  const [{ data: ficha }, { data: pedidos }, { data: recibos }, { data: ficheiros }] = await Promise.all([
    client.from('empresa_fichas').select('tem_trabalhadores').eq('company_id', id).maybeSingle(),
    client.from('empresa_pessoal').select('id,tipo,trabalhador,dados,estado,resposta,criado_em').eq('company_id', id).order('criado_em', { ascending: false }).limit(80),
    client.from('empresa_recibos').select('id,mes,publicado_em,descarregado_em').eq('company_id', id).order('mes', { ascending: false }).limit(24),
    client.from('empresa_ficheiros').select('id,ref_id,nome,contexto').eq('company_id', id).in('contexto', ['pessoal', 'recibos']).eq('estado', 'carregado'),
  ]);
  const anexos = (ref: string) => ((ficheiros ?? []) as Ficheiro[]).filter((f) => f.ref_id === ref);
  return (
    <>
      {!ficha?.tem_trabalhadores && (
        <p className="aviso aviso-atencao">Esta empresa não está marcada com trabalhadores: o cliente não vê a secção Pessoal. Marque-o na Ficha.</p>
      )}
      <div className={c.duas}>
        <section className={c.caixa}>
          <h3>Comunicações do cliente</h3>
          {pedidos?.length ? (pedidos as Pedido[]).map((x) => (
            <div key={x.id} className={c.documento}>
              <div>
                <strong className="pequeno">{TIPOS_PESSOAL[x.tipo]?.titulo ?? x.tipo}: {x.trabalhador}</strong>
                <small>{dataHora(x.criado_em)}</small>
                <small>{Object.entries(x.dados).map(([k, v]) => `${rotuloPessoal(x.tipo, k)}: ${/^\d{4}-\d{2}-\d{2}$/.test(v) ? data(v) : v}`).join(' · ')}</small>
                {anexos(x.id).map((f) => <a key={f.id} href={`/empresas/${id}/ficheiro/${f.id}`} target="_blank" rel="noopener"><small>📎 {f.nome}</small></a>)}
                {x.resposta && <small>Resposta: {x.resposta}</small>}
              </div>
              <div className={c.estado}><span className={ESTADOS_PESSOAL[x.estado]?.classe}>{ESTADOS_PESSOAL[x.estado]?.texto ?? x.estado}</span></div>
              <form action={tratarPessoalGestao} className={c.devolver}>
                <input type="hidden" name="empresa" value={id} /><input type="hidden" name="pedido" value={x.id} />
                <select name="estado" className="entrada" defaultValue={x.estado === 'novo' ? 'em_tratamento' : x.estado} style={{ flex: '0 1 11rem' }}>
                  <option value="em_tratamento">Em tratamento</option><option value="tratado">Tratado</option><option value="devolvido">Devolver</option><option value="novo">Reabrir</option>
                </select>
                <input name="resposta" className="entrada" maxLength={1000} placeholder="Nota para o cliente (opcional)" defaultValue={x.resposta ?? ''} />
                <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">Guardar</Submeter>
              </form>
            </div>
          )) : <p className="pequeno suave">Sem comunicações.</p>}
        </section>
        <section className={c.caixa}>
          <h3>Recibos de vencimento · um PDF por mês</h3>
          <PublicarRecibos empresa={id} meses={mesesRecentes(6).map((m) => ({ valor: m, nome: nomeMes(m) }))} />
          {recibos?.length ? (
            <ul className={c.lista}>
              {recibos.map((r) => (
                <li key={r.id}>
                  <div>{nomeMes(r.mes.slice(0, 7))}<small>{r.publicado_em ? `Publicado a ${dataHora(r.publicado_em)}` : 'Por publicar'}{r.descarregado_em ? ` · descarregado a ${dataHora(r.descarregado_em)}` : ''}</small></div>
                  <span>{anexos(r.id).map((f) => <a key={f.id} className="btn btn-discreto btn-sm" href={`/empresas/${id}/ficheiro/${f.id}`} target="_blank" rel="noopener">Abrir</a>)}</span>
                </li>
              ))}
            </ul>
          ) : null}
        </section>
      </div>
    </>
  );
}

/* ------------------------------------------------------------ impostos */

type Imposto = { id: string; tipo: string; periodo: string; descricao: string | null; referencia: string | null; valor: number | null; prazo: string | null; estado: string; pago_em: string | null };

export async function AbaImpostos({ client, id, hoje }: Contexto) {
  const [{ data: impostos }, { data: ficheiros }] = await Promise.all([
    client.from('empresa_impostos').select('id,tipo,periodo,descricao,referencia,valor,prazo,estado,pago_em').eq('company_id', id)
      .order('prazo', { ascending: false, nullsFirst: false }).limit(150),
    client.from('empresa_ficheiros').select('id,ref_id,nome,contexto').eq('company_id', id).in('contexto', ['guia', 'comprovativo']).eq('estado', 'carregado'),
  ]);
  const anexos = (ref: string) => ((ficheiros ?? []) as Ficheiro[]).filter((f) => f.ref_id === ref);
  return (
    <div className={c.duas}>
      <section className={c.caixa}>
        <h3>Publicar um pagamento</h3>
        <form action={guardarImpostoGestao} className="pilha pilha-3">
          <input type="hidden" name="empresa" value={id} />
          <div className={c.campos}>
            <label className="campo"><span>Imposto</span>
              <select name="tipo" className="entrada" required defaultValue="IVA">{Object.entries(TIPOS_IMPOSTO).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
            </label>
            <label className="campo"><span>Período</span><input name="periodo" className="entrada" required maxLength={20} placeholder="2026-09 · 2026T3 · 2025" /></label>
            <label className="campo"><span>Valor (€)</span><input name="valor" className="entrada" inputMode="decimal" placeholder="1 234,56" /></label>
            <label className="campo"><span>Pagar até</span><input name="prazo" type="date" className="entrada" /></label>
          </div>
          <label className="campo"><span>Referência de pagamento (DUC, entidade/referência…)</span><input name="referencia" className="entrada" maxLength={200} /></label>
          <label className="campo"><span>Descrição (opcional)</span><input name="descricao" className="entrada" maxLength={300} placeholder="Ex.: IVA do 3.º trimestre" /></label>
          <label className="campo"><span>Guia (PDF, opcional)</span><input type="file" name="guia" accept="application/pdf,image/jpeg,image/png,image/webp" /></label>
          <small className="pequeno suave">O cliente vê-o em Impostos e recebe um email com o valor, o prazo e a referência.</small>
          <div className={c.acoes}><Submeter className="btn btn-sm" aDecorrer="A publicar…">Publicar e avisar</Submeter></div>
        </form>
      </section>
      <section className={c.caixa}>
        <h3>Pagamentos publicados</h3>
        {impostos?.length ? (impostos as Imposto[]).map((i) => {
          const atraso = i.estado !== 'pago' && i.prazo && i.prazo < hoje;
          return (
            <div key={i.id} className={c.documento}>
              <div>
                <strong className="pequeno">{TIPOS_IMPOSTO[i.tipo] ?? i.tipo} · {i.periodo}{i.valor != null ? ` · ${euros(Number(i.valor))}` : ''}</strong>
                <small>{i.prazo ? `Prazo ${data(i.prazo)}` : 'Sem prazo'}{i.referencia ? ` · ref. ${i.referencia}` : ''}{i.descricao ? ` · ${i.descricao}` : ''}</small>
                {anexos(i.id).map((f) => <a key={f.id} href={`/empresas/${id}/ficheiro/${f.id}`} target="_blank" rel="noopener"><small>{f.contexto === 'guia' ? '📄 Guia' : '✅ Comprovativo'}: {f.nome}</small></a>)}
              </div>
              <div className={c.estado}>
                <span className={`etiqueta ${i.estado === 'pago' ? 'etiqueta-positivo' : atraso ? 'etiqueta-critico' : 'etiqueta-atencao'}`}>
                  {i.estado === 'pago' ? `Pago${i.pago_em ? ` ${dataHora(i.pago_em)}` : ''}` : atraso ? 'Em atraso' : 'Por pagar'}
                </span>
              </div>
              <div className={c.devolver}>
                <form action={marcarImpostoGestao}>
                  <input type="hidden" name="empresa" value={id} /><input type="hidden" name="imposto" value={i.id} /><input type="hidden" name="pago" value={i.estado === 'pago' ? 'false' : 'true'} />
                  <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">{i.estado === 'pago' ? 'Marcar por pagar' : 'Marcar pago'}</Submeter>
                </form>
                <form action={guardarImpostoGestao} className={c.devolver} style={{ flex: '1 1 16rem' }}>
                  <input type="hidden" name="empresa" value={id} /><input type="hidden" name="imposto" value={i.id} />
                  <input type="hidden" name="tipo" value={i.tipo} /><input type="hidden" name="periodo" value={i.periodo} />
                  <input type="hidden" name="valor" value={i.valor ?? ''} /><input type="hidden" name="prazo" value={i.prazo ?? ''} />
                  <input type="hidden" name="referencia" value={i.referencia ?? ''} /><input type="hidden" name="descricao" value={i.descricao ?? ''} />
                  <input type="file" name="guia" accept="application/pdf,image/jpeg,image/png,image/webp" required aria-label="Juntar guia" />
                  <Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Juntar guia</Submeter>
                </form>
                <form action={apagarImpostoGestao}>
                  <input type="hidden" name="empresa" value={id} /><input type="hidden" name="imposto" value={i.id} />
                  <Submeter className="btn btn-discreto btn-sm" aDecorrer="…">Apagar</Submeter>
                </form>
              </div>
            </div>
          );
        }) : <p className="pequeno suave">Sem pagamentos publicados.</p>}
      </section>
    </div>
  );
}
