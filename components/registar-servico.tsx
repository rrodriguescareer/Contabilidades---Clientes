'use client';
import { useEffect } from 'react';

/* Regista o service worker depois de a página assentar, para não competir
   com o primeiro ecrã. Só em produção: em desenvolvimento a cache atrapalha. */
export function RegistarServico() {
  useEffect(() => {
    if (process.env.NODE_ENV !== 'production') return;
    if (!('serviceWorker' in navigator)) return;
    const registar = () => navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {});
    if (document.readyState === 'complete') registar();
    else window.addEventListener('load', registar, { once: true });
  }, []);
  return null;
}
