'use client';
import { useMemo, useState, useTransition } from 'react';
import { acaoPendencias } from '@/lib/secretaria-actions';
import { ESTADOS_PENDENCIA, TIPOS, dataPt, euros } from '@/lib/secretaria';
import s from './secretaria.module.css';

export type LinhaPendencia = {
  id: string; tipo: string; descricao: string; numero: string | null; data_documento: string | null; valor_cents: number | null;
  banco: string | null; origem: string; estado: string; acompanhar: boolean; documento_id: string | null; periodo: string;
};

const ORIGENS: Record<string, string> = { manual: 'Manual', importacao: 'Ficheiro', recorrente: 'Recorrente' };
const EM_BLOCO: [string, string][] = [['recebida', 'Marcar recebida'], ['associada', 'Marcar associada'], ['reabrir', 'Reabrir'], ['acompanhar', 'Acompanhar'], ['deixar', 'Deixar de acompanhar'], ['anular', 'Anular']];

export function TabelaPendencias({ linhas, voltar }: { linhas: LinhaPendencia[]; voltar: string }) {
  const [texto, setTexto] = useState('');
  const [tipo, setTipo] = useState('');
  const [banco, setBanco] = useState('');
  const [so, setSo] = useState(false);
  const [associadas, setAssociadas] = useState(false);
  const [marcadas, setMarcadas] = useState<Set<string>>(new Set());
  const [aCorrer, iniciar] = useTransition();

  const tipos = useMemo(() => [...new Set(linhas.map((l) => l.tipo))], [linhas]);
  const bancos = useMemo(() => [...new Set(linhas.map((l) => l.banco).filter(Boolean))] as string[], [linhas]);
  const visiveis = useMemo(() => {
    const t = texto.trim().toLowerCase();
    return linhas.filter((l) =>
      (associadas || !['associada', 'anulada'].includes(l.estado)) && (!tipo || l.tipo === tipo) && (!banco || l.banco === banco) && (!so || l.acompanhar) &&
      (!t || `${l.descricao} ${l.numero ?? ''} ${l.banco ?? ''}`.toLowerCase().includes(t)));
  }, [linhas, texto, tipo, banco, so, associadas]);

  const correr = (ids: string[], acao: string) => {
    const f = new FormData();
    ids.forEach((id) => f.append('ids', id));
    f.set('acao', acao);
    f.set('voltar', voltar);
    iniciar(async () => { await acaoPendencias(f); setMarcadas(new Set()); });
  };
  const mudar = (id: string) => setMarcadas((a) => { const n = new Set(a); if (!n.delete(id)) n.add(id); return n; });
  const todas = visiveis.length > 0 && visiveis.every((l) => marcadas.has(l.id));

  return (
    <div className="pilha pilha-3">
      <div className={s.filtrosTabela}>
        <input type="search" className="entrada" placeholder="Procurar documento…" aria-label="Procurar documento" value={texto} onChange={(e) => setTexto(e.target.value)} />
        <select className="entrada" aria-label="Tipo" value={tipo} onChange={(e) => setTipo(e.target.value)}>
          <option value="">Todos os tipos</option>
          {tipos.map((t) => <option key={t} value={t}>{TIPOS[t] ?? t}</option>)}
        </select>
        {bancos.length > 0 && (
          <select className="entrada" aria-label="Banco" value={banco} onChange={(e) => setBanco(e.target.value)}>
            <option value="">Todos os bancos</option>
            {bancos.map((b) => <option key={b} value={b}>{b}</option>)}
          </select>
        )}
        <label className={s.verifica}><input type="checkbox" checked={so} onChange={(e) => setSo(e.target.checked)} /> Só acompanhadas</label>
        <label className={s.verifica}><input type="checkbox" checked={associadas} onChange={(e) => setAssociadas(e.target.checked)} /> Mostrar associadas</label>
      </div>

      {marcadas.size > 0 && (
        <div className={s.selecao}>
          <strong>{marcadas.size} selecionada{marcadas.size === 1 ? '' : 's'}</strong>
          {EM_BLOCO.map(([a, n]) => <button type="button" key={a} disabled={aCorrer} onClick={() => correr([...marcadas], a)}>{n}</button>)}
        </div>
      )}

      {visiveis.length === 0 ? (
        <div className={`${s.bloco} ${s.vazioPequeno}`}>
          <strong>{linhas.length ? 'Nada com estes filtros' : 'Sem pendências neste período'}</strong>
          <span>{linhas.length ? 'Experimente mostrar as associadas ou limpar a procura.' : 'Crie uma pendência ou importe um ficheiro para começar.'}</span>
        </div>
      ) : (
        <div className={s.envolve}>
          <table className={s.tabela}>
            <thead>
              <tr>
                <th><input type="checkbox" aria-label="Selecionar todas" checked={todas}
                           onChange={() => setMarcadas(todas ? new Set() : new Set(visiveis.map((l) => l.id)))} /></th>
                <th>Documento</th><th className={s.direita}>Valor</th><th>Data</th><th>Estado</th><th>Processo</th><th className={s.direita}>Ações</th>
              </tr>
            </thead>
            <tbody>
              {visiveis.map((l) => (
                <tr key={l.id}>
                  <td data-rotulo="Selecionar"><input type="checkbox" aria-label={`Selecionar ${l.descricao}`} checked={marcadas.has(l.id)} onChange={() => mudar(l.id)} /></td>
                  <td data-rotulo="">
                    <div className={s.emissor}>
                      <span className={s.sigla} title={TIPOS[l.tipo]}>{l.tipo === 'OUTRO' ? 'OUT' : l.tipo}</span>
                      <div>
                        <strong>{l.descricao}</strong>
                        <span className={s.segundo}>{[TIPOS[l.tipo], l.numero, l.banco, ORIGENS[l.origem]].filter(Boolean).join(' · ')}</span>
                      </div>
                    </div>
                  </td>
                  <td data-rotulo="Valor" className={`${s.direita} numero`}>{l.valor_cents != null ? euros(l.valor_cents) : '—'}</td>
                  <td data-rotulo="Data" className={s.nowrap}>{dataPt(l.data_documento)}</td>
                  <td data-rotulo="Estado"><span className={ESTADOS_PENDENCIA[l.estado].classe}>{ESTADOS_PENDENCIA[l.estado].nome}</span></td>
                  <td data-rotulo="Processo">
                    <button type="button" className={s.sino} aria-pressed={l.acompanhar} disabled={aCorrer}
                            title={l.acompanhar ? 'Em acompanhamento. Deixar de acompanhar' : 'Acompanhar nos pedidos'}
                            aria-label={l.acompanhar ? 'Deixar de acompanhar' : 'Acompanhar'}
                            onClick={() => correr([l.id], l.acompanhar ? 'deixar' : 'acompanhar')}>
                      <svg width="16" height="16" viewBox="0 0 24 24" fill={l.acompanhar ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8" /><path d="M10 20a2 2 0 0 0 4 0" /></svg>
                    </button>
                  </td>
                  <td data-rotulo="">
                    <div className={s.linhaAcoes}>
                      {l.documento_id && <a className={s.acaoPequena} href={`/secretaria/documento/${l.documento_id}`} target="_blank" rel="noreferrer">Ver</a>}
                      {l.estado === 'pendente' && <button type="button" className={s.acaoPequena} disabled={aCorrer} onClick={() => correr([l.id], 'recebida')}>Marcar recebida</button>}
                      {l.estado === 'recebida' && <button type="button" className={s.acaoPequena} disabled={aCorrer} onClick={() => correr([l.id], 'associada')}>Marcar associada</button>}
                      {l.estado !== 'pendente' && <button type="button" className={s.acaoPequena} disabled={aCorrer} onClick={() => correr([l.id], 'reabrir')}>Reabrir</button>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
