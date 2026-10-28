import { ACarregar as ComChegada } from '@/components/chegada';

export default function ACarregar() {
  return (
    <ComChegada>
      <div className="envolve" style={{ paddingBlock: 'var(--e-7)', display: 'grid', gap: 'var(--e-4)' }} aria-busy="true">
        <span className="esqueleto" style={{ blockSize: '2.5rem', inlineSize: 'min(100%, 18rem)' }} />
        <span className="esqueleto" style={{ blockSize: '10rem' }} />
        <p role="status" className="so-leitor">A carregar.</p>
      </div>
    </ComChegada>
  );
}
