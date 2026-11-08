'use client';
import { useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import e from './consola.module.css';

/* A casca do menu: em computador pode recolher-se aos ícones (fica lembrado);
   em telemóvel vira uma gaveta, aberta pelo botão da barra de topo. */
export function MenuLateral({ marca, children }: { marca: React.ReactNode; children: React.ReactNode }) {
  const [aberto, setAberto] = useState(false);
  const [recolhido, setRecolhido] = useState(false);
  const caminho = usePathname();

  useEffect(() => { setAberto(false); }, [caminho]);
  useEffect(() => {
    try { setRecolhido(localStorage.getItem('rr_menu') === 'recolhido'); } catch { /* sem armazenamento */ }
  }, []);
  useEffect(() => {
    if (!aberto) return;
    const fechar = (ev: KeyboardEvent) => { if (ev.key === 'Escape') setAberto(false); };
    window.addEventListener('keydown', fechar);
    return () => window.removeEventListener('keydown', fechar);
  }, [aberto]);

  const alternar = () => setRecolhido((r) => {
    try { localStorage.setItem('rr_menu', r ? 'aberto' : 'recolhido'); } catch { /* sem armazenamento */ }
    return !r;
  });

  return (
    <>
      <div className={e.barraMovel}>
        {marca}
        <button type="button" className={e.abrirMenu} aria-label="Abrir o menu" aria-expanded={aberto} onClick={() => setAberto(true)}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
        </button>
      </div>
      {aberto && <button type="button" className={e.veu} aria-label="Fechar o menu" onClick={() => setAberto(false)} />}
      <aside className={e.lateral} data-aberto={aberto ? 'true' : undefined} data-recolhido={recolhido ? 'true' : undefined}>
        <div className={e.lateralTopo}>
          <div className={e.soAberto}>{marca}</div>
          <button type="button" className={e.recolher} onClick={alternar} aria-label={recolhido ? 'Expandir o menu' : 'Recolher o menu'} title={recolhido ? 'Expandir o menu' : 'Recolher o menu'}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2.5" /><path d="M9 4v16" /></svg>
          </button>
        </div>
        {children}
      </aside>
    </>
  );
}
