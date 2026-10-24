import Link from 'next/link';

export default function NaoEncontrado() {
  return (
    <main id="principal" className="envolve" style={{ minHeight: '100dvh', display: 'grid', placeContent: 'center', gap: 'var(--e-4)', textAlign: 'center' }}>
      <img src="/rr.svg" alt="RR." width={294} height={195} style={{ height: 28, width: 'auto', margin: '0 auto' }} />
      <h1>Página não encontrada</h1>
      <p className="suave" style={{ maxWidth: '42ch' }}>O endereço pode ter mudado.</p>
      <Link className="btn" href="/" style={{ justifySelf: 'center' }}>
        Ir para o início
      </Link>
    </main>
  );
}
