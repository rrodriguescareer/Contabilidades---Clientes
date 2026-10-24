'use client';
import Link from 'next/link';

export default function Erro({ reset }: { reset: () => void }) {
  return (
    <main id="principal" className="envolve" style={{ minHeight: '100dvh', display: 'grid', placeContent: 'center', gap: 'var(--e-4)', textAlign: 'center' }}>
      <img src="/rr.svg" alt="RR." width={294} height={195} style={{ height: 28, width: 'auto', margin: '0 auto' }} />
      <h1>Não foi possível concluir o pedido.</h1>
      <p className="suave" style={{ maxWidth: '42ch' }}>
        Tente novamente. Se continuar, escreva-me para contabilidade.rubenrodrigues@gmail.com.
      </p>
      <div className="linha" style={{ justifyContent: 'center' }}>
        <button className="btn" onClick={reset}>
          Tentar novamente
        </button>
        <Link href="/entrar" className="btn btn-secundario">
          Voltar à entrada
        </Link>
      </div>
    </main>
  );
}
