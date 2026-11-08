'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { procurar } from '@/lib/secretaria-actions';
import e from './consola.module.css';

type Resultado = { id: string; nome: string; nif: string };

/* Procurar cliente ou NIF, de qualquer ecrã. Ctrl+K (⌘K no Mac). */
export function ProcuraGlobal() {
  const janela = useRef<HTMLDialogElement>(null);
  const campo = useRef<HTMLInputElement>(null);
  const [termo, setTermo] = useState('');
  const [resultados, setResultados] = useState<Resultado[]>([]);
  const [ativo, setAtivo] = useState(0);
  const [aProcurar, setAProcurar] = useState(false);
  const router = useRouter();

  const abrir = () => { setTermo(''); setResultados([]); setAtivo(0); janela.current?.showModal(); campo.current?.focus(); };
  const fechar = () => janela.current?.close();

  useEffect(() => {
    const atalho = (ev: KeyboardEvent) => {
      if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 'k') {
        ev.preventDefault();
        if (janela.current?.open) fechar(); else abrir();
      }
    };
    window.addEventListener('keydown', atalho);
    return () => window.removeEventListener('keydown', atalho);
  }, []);

  useEffect(() => {
    if (termo.trim().length < 2) { setResultados([]); setAProcurar(false); return; }
    setAProcurar(true);
    let cancelado = false;
    const espera = setTimeout(async () => {
      const r = await procurar(termo).catch(() => []);
      if (!cancelado) { setResultados(r); setAtivo(0); setAProcurar(false); }
    }, 250);
    return () => { cancelado = true; clearTimeout(espera); };
  }, [termo]);

  const ir = (r: Resultado) => { fechar(); router.push(`/secretaria/clientes/${r.id}`); };
  const teclas = (ev: React.KeyboardEvent) => {
    if (ev.key === 'ArrowDown') { ev.preventDefault(); setAtivo((a) => Math.min(a + 1, resultados.length - 1)); }
    if (ev.key === 'ArrowUp') { ev.preventDefault(); setAtivo((a) => Math.max(a - 1, 0)); }
    if (ev.key === 'Enter' && resultados[ativo]) { ev.preventDefault(); ir(resultados[ativo]); }
  };

  return (
    <>
      <button type="button" className={e.procuraBotao} onClick={abrir} aria-label="Procurar cliente ou NIF">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>
        <span className={e.navNome}>Procurar cliente ou NIF</span>
        <kbd>Ctrl K</kbd>
      </button>
      <dialog ref={janela} className={e.procuraJanela} aria-label="Procurar cliente ou NIF" onClick={(ev) => { if (ev.target === janela.current) fechar(); }}>
        <input ref={campo} className={e.procuraCampo} type="search" placeholder="Procurar cliente ou NIF…" aria-label="Procurar cliente ou NIF" value={termo}
               onChange={(ev) => setTermo(ev.target.value)} onKeyDown={teclas} />
        {resultados.length > 0 ? (
          <ul className={e.procuraLista}>
            {resultados.map((r, i) => (
              <li key={r.id}>
                <button type="button" data-ativo={i === ativo ? 'true' : undefined} onMouseEnter={() => setAtivo(i)} onClick={() => ir(r)}>
                  <strong>{r.nome}</strong><span>NIF {r.nif}</span>
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <p className={e.procuraVazio}>{aProcurar ? 'A procurar…' : termo.trim().length >= 2 ? 'Sem resultados.' : 'Escreva o nome ou o NIF.'}</p>
        )}
      </dialog>
    </>
  );
}
