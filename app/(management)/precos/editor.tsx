'use client';
import { useRouter } from 'next/navigation';
import { useEffect, useMemo, useState, useTransition } from 'react';
import { criarPoliticaRegras, simularPreco } from '@/lib/precos-actions';
import { CATEGORIAS, MEDIDAS, MODOS, type Condicao, type Regra } from '@/lib/precos-regras';

/* O editor de uma política: as regras numa lista, cada uma com o rótulo, o
   valor, as condições, a cobrança por unidade e o que anula. Ao lado, um
   simulador que calcula o preço de um processo imaginado com as regras tal
   como estão no ecrã, antes de as gravar. */

type Linha = Omit<Regra, 'valor_cents'> & { chave: string; valor: string };

let contador = 0;
const chave = () => `r${++contador}`;
const paraLinha = (r: Regra): Linha => ({ ...r, chave: chave(), valor: ((r.valor_cents || 0) / 100).toFixed(2), anula: r.anula ?? [], condicoes: r.condicoes ?? [] });
const paraRegra = ({ chave: _, valor, ...r }: Linha): Regra =>
  ({ ...r, valor_cents: Math.round(Number(String(valor).replace(',', '.')) * 100) || 0, por_unidade: r.por_unidade || null });
const codigoDe = (t: string, usados: string[]) => {
  const base = t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 30) || 'regra';
  let c = base, i = 2;
  while (usados.includes(c)) c = `${base}_${i++}`;
  return c;
};
const euros = (c: number) => new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' }).format((c || 0) / 100);

export function EditorPrecos({ inicial, nomeInicial, notasInicial, minimoInicial, maximoInicial, origem, simular = true }: {
  inicial: Regra[]; nomeInicial: string; notasInicial: string; minimoInicial: number | null; maximoInicial: number | null; origem: string | null;
  simular?: boolean;
}) {
  const router = useRouter();
  const [linhas, setLinhas] = useState<Linha[]>(() => inicial.map(paraLinha));
  const [nome, setNome] = useState(nomeInicial);
  const [notas, setNotas] = useState(notasInicial);
  const [minimo, setMinimo] = useState(minimoInicial != null ? (minimoInicial / 100).toFixed(2) : '');
  const [maximo, setMaximo] = useState(maximoInicial != null ? (maximoInicial / 100).toFixed(2) : '');
  const [ativar, setAtivar] = useState(false);
  const [estado, setEstado] = useState<{ ok?: string; erro?: string } | null>(null);
  const [aGuardar, guardar] = useTransition();

  // Mudar o código de uma regra muda-o também onde outras a anulam.
  const mudar = (k: string, m: Partial<Linha>) => setLinhas((ls) => {
    const antigo = ls.find((l) => l.chave === k)?.id;
    return ls.map((l) => {
      if (l.chave === k) return { ...l, ...m };
      if (m.id && antigo && (l.anula ?? []).includes(antigo)) return { ...l, anula: (l.anula ?? []).map((a) => (a === antigo ? m.id! : a)) };
      return l;
    });
  });
  const mover = (k: string, d: -1 | 1) => setLinhas((ls) => {
    const i = ls.findIndex((l) => l.chave === k), j = i + d;
    if (j < 0 || j >= ls.length) return ls;
    const n = [...ls]; [n[i], n[j]] = [n[j], n[i]]; return n;
  });
  const tirar = (k: string) => setLinhas((ls) => {
    const id = ls.find((l) => l.chave === k)?.id;
    return ls.filter((l) => l.chave !== k).map((l) => ({ ...l, anula: (l.anula ?? []).filter((a) => a !== id) }));
  });
  const nova = () => setLinhas((ls) => [...ls, {
    chave: chave(), id: codigoDe('nova regra', ls.map((l) => l.id)), rotulo: 'Nova regra', valor: '0.00', ativa: true, condicoes: [], anula: [], por_unidade: null,
  }]);
  const cents = (v: string) => (v.trim() === '' ? null : Math.round(Number(v.replace(',', '.')) * 100));

  function submeter(e: React.FormEvent) {
    e.preventDefault();
    setEstado(null);
    guardar(async () => {
      const r = await criarPoliticaRegras({
        nome, notas, regras: linhas.map(paraRegra), minimo: cents(minimo), maximo: cents(maximo), origem, ativar,
      });
      setEstado(r);
      if (r.ok) router.refresh();
    });
  }

  return (
    <form onSubmit={submeter} className="pilha pilha-4">
      <div className="cartao pilha pilha-4">
        <div className="grelha grelha-auto">
          <label className="campo"><span>Nome da política</span>
            <input className="entrada" required maxLength={120} value={nome} onChange={(e) => setNome(e.target.value)} placeholder="IRS 2027 — tabela base" />
          </label>
          <label className="campo"><span>Preço mínimo (€, opcional)</span>
            <input className="entrada" inputMode="decimal" value={minimo} onChange={(e) => setMinimo(e.target.value)} placeholder="—" />
          </label>
          <label className="campo"><span>Preço máximo (€, opcional)</span>
            <input className="entrada" inputMode="decimal" value={maximo} onChange={(e) => setMaximo(e.target.value)} placeholder="—" />
          </label>
        </div>
        <label className="campo"><span>Notas internas</span>
          <textarea className="entrada" rows={2} maxLength={500} value={notas} onChange={(e) => setNotas(e.target.value)} />
        </label>
      </div>

      <div className="pilha pilha-3">
        {linhas.map((l, i) => (
          <RegraEditavel key={l.chave} l={l} i={i} total={linhas.length} todas={linhas}
                         mudar={(m) => mudar(l.chave, m)} mover={(d) => mover(l.chave, d)} tirar={() => tirar(l.chave)} />
        ))}
        <div><button type="button" className="btn btn-secundario" onClick={nova}>+ Nova regra</button></div>
      </div>

      {simular && <Simulador linhas={linhas} minimo={cents(minimo)} maximo={cents(maximo)} />}

      <div className="cartao pilha pilha-3">
        <label className="caixa">
          <input type="checkbox" checked={ativar} onChange={(e) => setAtivar(e.target.checked)} />
          <span className="pequeno">Pôr em vigor logo que guardar (senão fica no histórico, pronta para quando quiser)</span>
        </label>
        {estado?.erro && <p className="aviso aviso-critico" role="alert">{estado.erro}</p>}
        {estado?.ok && <p className="aviso aviso-positivo" role="status">{estado.ok}</p>}
        <div><button className="btn" type="submit" disabled={aGuardar}>{aGuardar ? 'A guardar…' : 'Guardar como nova versão'}</button></div>
      </div>
    </form>
  );
}

function RegraEditavel({ l, i, total, todas, mudar, mover, tirar }: {
  l: Linha; i: number; total: number; todas: Linha[]; mudar: (m: Partial<Linha>) => void; mover: (d: -1 | 1) => void; tirar: () => void;
}) {
  const conds = l.condicoes ?? [];
  const mudarCond = (j: number, c: Condicao) => mudar({ condicoes: conds.map((x, k) => (k === j ? c : x)) });
  return (
    <div className="cartao pilha pilha-3" style={{ opacity: l.ativa === false ? 0.6 : 1 }}>
      <div className="grelha" style={{ gridTemplateColumns: 'minmax(0, 1fr) 8rem auto', gap: 'var(--e-3)', alignItems: 'end' }}>
        <label className="campo"><span>{i + 1}. Rótulo que o cliente vê</span>
          <input className="entrada" required maxLength={160} value={l.rotulo} onChange={(e) => mudar({ rotulo: e.target.value })} />
        </label>
        <label className="campo"><span>Valor (€)</span>
          <input className="entrada" inputMode="decimal" required value={l.valor} onChange={(e) => mudar({ valor: e.target.value })} />
        </label>
        <div className="linha" style={{ gap: '.25rem' }}>
          <button type="button" className="btn btn-discreto btn-sm" onClick={() => mover(-1)} disabled={i === 0} aria-label="Subir">↑</button>
          <button type="button" className="btn btn-discreto btn-sm" onClick={() => mover(1)} disabled={i === total - 1} aria-label="Descer">↓</button>
          <button type="button" className="btn btn-discreto btn-sm" onClick={tirar} aria-label="Apagar a regra">✕</button>
        </div>
      </div>
      <div className="linha" style={{ flexWrap: 'wrap', gap: 'var(--e-4)' }}>
        <label className="caixa"><input type="checkbox" checked={l.ativa !== false} onChange={(e) => mudar({ ativa: e.target.checked })} /><span className="pequeno">Ativa</span></label>
        <label className="campo" style={{ maxInlineSize: '14rem' }}><span className="micro">Código interno</span>
          <input className="entrada" pattern="[a-z0-9_-]{1,40}" maxLength={40} value={l.id} onChange={(e) => mudar({ id: e.target.value.toLowerCase() })} />
        </label>
        <span className="micro tenue">No rótulo, «{'{n}'}» é substituído pela quantidade (ex.: «Rendas — {'{n}'} imóveis»).</span>
      </div>

      <div className="pilha pilha-2">
        <strong className="pequeno">Aplica-se quando {conds.length ? '(todas as condições)' : '— sempre'}</strong>
        {conds.map((c, j) => (
          <div key={j} className="linha" style={{ flexWrap: 'wrap', gap: 'var(--e-2)', alignItems: 'center' }}>
            <select className="entrada" style={{ inlineSize: 'auto' }} value={c.tipo}
                    onChange={(e) => mudarCond(j, e.target.value === 'categoria'
                      ? { tipo: 'categoria', modo: 'alguma', categorias: ['employment'] }
                      : { tipo: 'contagem', medida: 'imoveis_renda', min: 1, max: null })}>
              <option value="categoria">Rendimentos</option>
              <option value="contagem">Quantidade</option>
            </select>
            {c.tipo === 'categoria' ? (
              <>
                <select className="entrada" style={{ inlineSize: 'auto' }} value={c.modo} onChange={(e) => mudarCond(j, { ...c, modo: e.target.value as typeof c.modo })}>
                  {Object.entries(MODOS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
                {Object.entries(CATEGORIAS).map(([v, t]) => (
                  <label key={v} className="caixa" style={{ alignItems: 'center' }}>
                    <input type="checkbox" checked={c.categorias.includes(v)}
                           onChange={(e) => mudarCond(j, { ...c, categorias: e.target.checked ? [...c.categorias, v] : c.categorias.filter((x) => x !== v) })} />
                    <span className="micro">{t}</span>
                  </label>
                ))}
              </>
            ) : (
              <>
                <select className="entrada" style={{ inlineSize: 'auto' }} value={c.medida} onChange={(e) => mudarCond(j, { ...c, medida: e.target.value })}>
                  {Object.entries(MEDIDAS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
                </select>
                <span className="micro">de</span>
                <input className="entrada" style={{ inlineSize: '5rem' }} inputMode="numeric" placeholder="—" value={c.min ?? ''}
                       onChange={(e) => mudarCond(j, { ...c, min: e.target.value === '' ? null : Number(e.target.value) })} />
                <span className="micro">a</span>
                <input className="entrada" style={{ inlineSize: '5rem' }} inputMode="numeric" placeholder="—" value={c.max ?? ''}
                       onChange={(e) => mudarCond(j, { ...c, max: e.target.value === '' ? null : Number(e.target.value) })} />
              </>
            )}
            <button type="button" className="btn-texto" onClick={() => mudar({ condicoes: conds.filter((_, k) => k !== j) })}>Retirar</button>
          </div>
        ))}
        <div><button type="button" className="btn btn-discreto btn-sm" onClick={() => mudar({ condicoes: [...conds, { tipo: 'categoria', modo: 'alguma', categorias: ['employment'] }] })}>+ Condição</button></div>
      </div>

      <div className="linha" style={{ flexWrap: 'wrap', gap: 'var(--e-2)', alignItems: 'center' }}>
        <label className="caixa" style={{ alignItems: 'center' }}>
          <input type="checkbox" checked={Boolean(l.por_unidade)}
                 onChange={(e) => mudar({ por_unidade: e.target.checked ? { medida: 'imoveis_venda', acima_de: 0 } : null })} />
          <span className="pequeno">Cobrar por unidade</span>
        </label>
        {l.por_unidade && (
          <>
            <select className="entrada" style={{ inlineSize: 'auto' }} value={l.por_unidade.medida}
                    onChange={(e) => mudar({ por_unidade: { ...l.por_unidade!, medida: e.target.value } })}>
              {Object.entries(MEDIDAS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
            </select>
            <span className="micro">acima de</span>
            <input className="entrada" style={{ inlineSize: '5rem' }} inputMode="numeric" value={l.por_unidade.acima_de}
                   onChange={(e) => mudar({ por_unidade: { ...l.por_unidade!, acima_de: Number(e.target.value) || 0 } })} />
          </>
        )}
      </div>

      {todas.length > 1 && (
        <div className="pilha pilha-2">
          <strong className="pequeno">Quando se aplica, anula</strong>
          <div className="linha" style={{ flexWrap: 'wrap', gap: 'var(--e-3)' }}>
            {todas.filter((o) => o.chave !== l.chave).map((o) => (
              <label key={o.chave} className="caixa" style={{ alignItems: 'center' }}>
                <input type="checkbox" checked={(l.anula ?? []).includes(o.id)}
                       onChange={(e) => mudar({ anula: e.target.checked ? [...(l.anula ?? []), o.id] : (l.anula ?? []).filter((x) => x !== o.id) })} />
                <span className="micro">{o.rotulo}</span>
              </label>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

/** O preço de um processo imaginado, com as regras tal como estão no ecrã. */
function Simulador({ linhas, minimo, maximo }: { linhas: Linha[]; minimo: number | null; maximo: number | null }) {
  const [categorias, setCategorias] = useState<string[]>(['employment']);
  const [medidas, setMedidas] = useState<Record<string, number>>({ pessoas_trabalho: 1, membros: 1 });
  const [resultado, setResultado] = useState<Awaited<ReturnType<typeof simularPreco>> | null>(null);
  const regras = useMemo(() => linhas.map(paraRegra), [linhas]);
  const m = useMemo(() => ({ ...medidas, categorias, tipos_rendimento: categorias.length }), [medidas, categorias]);

  useEffect(() => {
    const t = setTimeout(() => { simularPreco(regras, m, minimo, maximo).then(setResultado).catch(() => {}); }, 350);
    return () => clearTimeout(t);
  }, [regras, m, minimo, maximo]);

  return (
    <div className="cartao pilha pilha-3" style={{ borderInlineStart: '4px solid var(--acao)' }}>
      <h3 style={{ margin: 0 }}>Simulador</h3>
      <p className="micro tenue">Um processo imaginado: escolha os rendimentos e as quantidades. O preço atualiza-se com as regras acima, ainda por gravar.</p>
      <div className="linha" style={{ flexWrap: 'wrap', gap: 'var(--e-3)' }}>
        {Object.entries(CATEGORIAS).map(([v, t]) => (
          <label key={v} className="caixa" style={{ alignItems: 'center' }}>
            <input type="checkbox" checked={categorias.includes(v)}
                   onChange={(e) => setCategorias(e.target.checked ? [...categorias, v] : categorias.filter((x) => x !== v))} />
            <span className="micro">{t}</span>
          </label>
        ))}
      </div>
      <div className="grelha grelha-auto">
        {Object.entries(MEDIDAS).filter(([k]) => k !== 'tipos_rendimento').map(([k, t]) => (
          <label key={k} className="campo"><span className="micro">{t}</span>
            <input className="entrada" inputMode="numeric" value={medidas[k] ?? 0}
                   onChange={(e) => setMedidas({ ...medidas, [k]: Math.max(0, Number(e.target.value) || 0) })} />
          </label>
        ))}
      </div>
      {resultado?.erro ? <p className="aviso aviso-atencao">{resultado.erro}</p> : resultado?.items && (
        <table className="tabela">
          <tbody>
            {resultado.items.map((x, i) => <tr key={i}><td>{x.label}</td><td style={{ textAlign: 'right' }}>{euros(x.amount_cents)}</td></tr>)}
            <tr><td><strong>Total (IVA incluído)</strong></td><td style={{ textAlign: 'right' }}><strong>{euros(resultado.subtotal_cents ?? 0)}</strong></td></tr>
          </tbody>
        </table>
      )}
    </div>
  );
}
