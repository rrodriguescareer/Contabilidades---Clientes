'use client';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { useFormStatus } from 'react-dom';

/* A transição da entrada, em três tempos que partilham o mesmo ecrã. A marca
   fica sempre no mesmo sítio; só muda a frase por baixo:
   1. "A entrar…"  — no clique em Entrar, enquanto a palavra-passe é verificada;
   2. "A entrar…"  — enquanto o portal carrega (o loading.tsx);
   3. "Olá, Nome." — o portal já está desenhado por baixo, e a cortina sobe.
   Liga-os o cookie de 30 segundos que o signIn deixa (rr_chegada). */

const SINAL = 'rr_chegada=1';
const temSinal = () => document.cookie.split('; ').includes(SINAL);
const semSubscricao = () => () => {};

function Ecra({ texto, fase, espera, entrada }: {
  texto: string; fase?: 'ola' | 'sair'; espera?: boolean; entrada?: boolean;
}) {
  return (
    <div className="chegada" data-fase={fase} data-entrada={entrada || undefined} aria-hidden="true">
      <div className="chegada-centro">
        <img src="/rr-branco.svg" alt="" width={259} height={142} className="chegada-marca" />
        <p className="chegada-texto" key={texto}>{texto}</p>
        <span className="chegada-barra" data-espera={espera || undefined} />
      </div>
    </div>
  );
}

/** 1. Dentro do formulário de entrada. Se a palavra-passe falhar, a página
    volta com o erro e o ecrã sai com o fim do envio. */
export function AEntrar() {
  const { pending } = useFormStatus();
  return pending ? <Ecra texto="A entrar…" espera entrada /> : null;
}

/** 2. O loading.tsx do portal: logo a seguir à entrada, o mesmo ecrã em vez
    do esqueleto, para nada piscar entre o clique e o painel. */
export function ACarregar({ children }: { children: React.ReactNode }) {
  const sinal = useSyncExternalStore(semSubscricao, temSinal, () => false);
  return sinal ? <Ecra texto="A entrar…" espera /> : <>{children}</>;
}

/** 3. No portal. O servidor já sabe se há sinal, por isso o ecrã vem no
    primeiro HTML e o painel nunca aparece antes dele. Os tempos dependem só
    da fase: um refresh a meio não deixa o ecrã preso. */
export function Chegada({ ativo, nome }: { ativo: boolean; nome?: string | null }) {
  const [fase, setFase] = useState<'ola' | 'sair' | 'nada'>(ativo ? 'ola' : 'nada');

  useEffect(() => {
    if (fase === 'nada') return;
    if (fase === 'ola') document.cookie = 'rr_chegada=; Max-Age=0; path=/; SameSite=Lax';
    const reduzido = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const espera = reduzido ? 0 : fase === 'ola' ? 1200 : 700;
    const t = window.setTimeout(() => setFase(fase === 'ola' ? 'sair' : 'nada'), espera);
    return () => window.clearTimeout(t);
  }, [fase]);

  if (fase === 'nada') return null;
  const primeiro = (nome || '').trim().split(/\s+/)[0];
  return <Ecra texto={primeiro ? `Olá, ${primeiro}.` : 'Bem-vindo.'} fase={fase} />;
}
