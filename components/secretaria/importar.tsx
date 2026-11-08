'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { importarPendencias } from '@/lib/secretaria-actions';
import { lerFolha } from '@/lib/ler-folha';
import { TIPOS, dataPt, euros, interpretarFolha, type Importacao } from '@/lib/secretaria';
import s from './secretaria.module.css';

/* Importar pendências de um Excel ou CSV: lê no browser, mostra o que entra e
   o que não entra, e só depois grava. */
export function Importar({ empresa, periodoPadrao }: { empresa: string; periodoPadrao: string }) {
  const [leitura, setLeitura] = useState<Importacao | null>(null);
  const [nome, setNome] = useState('');
  const [periodo, setPeriodo] = useState(periodoPadrao);
  const [aviso, setAviso] = useState<{ ok?: string; erro?: string } | null>(null);
  const [aCorrer, iniciar] = useTransition();
  const router = useRouter();

  const abrir = async (f?: File) => {
    setAviso(null);
    setLeitura(null);
    if (!f) return;
    setNome(f.name);
    try {
      if (f.size > 8 * 1024 * 1024) throw new Error('O ficheiro tem mais de 8 MB.');
      setLeitura(interpretarFolha(await lerFolha(f)));
    } catch (e) {
      setAviso({ erro: (e as Error).message || 'Não foi possível ler o ficheiro.' });
    }
  };
  const semData = (leitura?.linhas ?? []).filter((l) => !l.data).length;
  const importar = () => iniciar(async () => {
    const r = await importarPendencias(empresa, periodo, leitura?.linhas ?? []);
    setAviso(r);
    if (r.ok) { setLeitura(null); router.refresh(); }
  });

  return (
    <div className="pilha pilha-4">
      <p className="pequeno suave">Excel (.xlsx) ou CSV, até 2000 linhas. Colunas: Descrição, Tipo de documento, N.º do documento, Data do documento, Valor e Banco (opcional).</p>
      <label className="campo">
        <span>Ficheiro</span>
        <input type="file" className="entrada" accept=".xlsx,.csv,.txt" onChange={(e) => abrir(e.target.files?.[0])} />
      </label>
      {aviso?.erro && <p className="aviso aviso-critico" role="alert">{aviso.erro}</p>}
      {aviso?.ok && <p className="aviso aviso-positivo" role="status">{aviso.ok}</p>}
      {leitura && (
        <>
          <div className={s.faixa} data-tom={leitura.recusadas.length ? 'atencao' : 'positivo'}>
            <span><strong>{leitura.linhas.length} a importar</strong> de «{nome}»{leitura.recusadas.length ? ` · ${leitura.recusadas.length} não entram` : ''}</span>
          </div>
          {semData > 0 && (
            <label className="campo">
              <span>Período das {semData} linhas sem data</span>
              <input type="month" className="entrada" value={periodo} onChange={(e) => setPeriodo(e.target.value)} />
            </label>
          )}
          {leitura.linhas.length > 0 && (
            <div className={s.envolve} style={{ maxBlockSize: '16rem', overflowY: 'auto' }}>
              <table className={s.tabela}>
                <thead><tr><th>Descrição</th><th>Tipo</th><th>N.º</th><th>Data</th><th className={s.direita}>Valor</th></tr></thead>
                <tbody>
                  {leitura.linhas.slice(0, 50).map((l, i) => (
                    <tr key={i}>
                      <td data-rotulo="">{l.descricao}</td>
                      <td data-rotulo="Tipo">{TIPOS[l.tipo]}</td>
                      <td data-rotulo="N.º">{l.numero ?? '—'}</td>
                      <td data-rotulo="Data">{dataPt(l.data)}</td>
                      <td data-rotulo="Valor" className={s.direita}>{l.valor_cents != null ? euros(l.valor_cents) : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {leitura.recusadas.length > 0 && (
            <ul className="pequeno suave" style={{ paddingInlineStart: '1.1rem' }}>
              {leitura.recusadas.slice(0, 6).map((r, i) => <li key={i}>{r.linha ? `Linha ${r.linha}: ` : ''}{r.motivo}</li>)}
              {leitura.recusadas.length > 6 && <li>e mais {leitura.recusadas.length - 6}.</li>}
            </ul>
          )}
          <div className={s.linhaBotoes}>
            <button type="button" className="btn btn-sm" disabled={aCorrer || !leitura.linhas.length} onClick={importar}>
              {aCorrer ? 'A importar…' : `Importar ${leitura.linhas.length}`}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
