'use client';
import { useEffect } from 'react';
import e from './gabinete.module.css';

export type Notificacao = { tom: 'ok' | 'atencao' | 'erro'; titulo: string; detalhes?: string[] };

/* O resultado de uma operação com integrações (reembolso, pedido de
   pagamento): no canto do ecrã, onde não se perde, com um título curto e uma
   linha por integração. Fecha sozinha quando correu tudo bem. */
export function AvisoFlutuante({ aviso, fechar }: { aviso: Notificacao | null; fechar: () => void }) {
  useEffect(() => {
    if (aviso?.tom !== 'ok') return;
    const t = window.setTimeout(fechar, 7000);
    return () => window.clearTimeout(t);
  }, [aviso, fechar]);
  if (!aviso) return null;
  return (
    <div className={e.notificacao} data-tom={aviso.tom} role={aviso.tom === 'erro' ? 'alert' : 'status'}>
      <span className={e.notificacaoIcone} aria-hidden="true">
        {aviso.tom === 'ok' ? (
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
        ) : (
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><path d="M12 7v6" /><circle cx="12" cy="17" r=".6" fill="currentColor" /></svg>
        )}
      </span>
      <div>
        <strong>{aviso.titulo}</strong>
        {aviso.detalhes?.length ? <ul>{aviso.detalhes.map((d) => <li key={d}>{d}</li>)}</ul> : null}
      </div>
      <button type="button" onClick={fechar} aria-label="Fechar">×</button>
    </div>
  );
}
