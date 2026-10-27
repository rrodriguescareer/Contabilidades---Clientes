'use client';
import { useEffect, useState } from 'react';

/* A entrada depois do login. O signIn deixa um cookie de vida curta; quem o
   encontrar mostra a transição uma vez e apaga-o. Assim funciona qualquer que
   seja o destino (área do cliente ou gabinete) e não se repete ao recarregar. */
export function Chegada({ nome }: { nome?: string | null }) {
  const [fase, setFase] = useState<'nada' | 'entrar' | 'sair'>('nada');

  useEffect(() => {
    if (!document.cookie.split('; ').some((c) => c === 'rr_chegada=1')) return;
    document.cookie = 'rr_chegada=; Max-Age=0; path=/; SameSite=Lax';
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    setFase('entrar');
    const sair = window.setTimeout(() => setFase('sair'), 1150);
    const fim = window.setTimeout(() => setFase('nada'), 1900);
    return () => { window.clearTimeout(sair); window.clearTimeout(fim); };
  }, []);

  if (fase === 'nada') return null;
  const primeiro = (nome || '').trim().split(/\s+/)[0];

  return (
    <div className="chegada" data-fase={fase} aria-hidden="true">
      <div className="chegada-centro">
        <img src="/rr-branco.svg" alt="" width={259} height={142} className="chegada-marca" />
        <p className="chegada-texto">{primeiro ? `Olá, ${primeiro}.` : 'Bem-vindo.'}</p>
        <span className="chegada-barra" />
      </div>
    </div>
  );
}
