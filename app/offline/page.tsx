export const metadata = { title: 'Sem ligação' };

export default function SemLigacao() {
  return (
    <main id="principal" className="envolve" style={{ minHeight: '100dvh', display: 'grid', placeContent: 'center', gap: 'var(--e-4)', textAlign: 'center' }}>
      <img src="/rr.svg" alt="RR." width={259} height={142} style={{ height: 30, width: 'auto', margin: '0 auto' }} />
      <h1>Está sem ligação.</h1>
      <p className="suave" style={{ maxWidth: '40ch' }}>A gestão precisa de internet. Recarregue assim que a ligação voltar.</p>
    </main>
  );
}
