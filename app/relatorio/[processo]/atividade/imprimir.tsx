'use client';

/* Os botões do ecrã. Não saem na impressão. */
export function Imprimir({ csv }: { csv: string }) {
  return (
    <div className="nao-imprimir" style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end', marginBlockEnd: '1rem' }}>
      <a className="btn btn-secundario btn-sm" href={csv}>Descarregar em Excel (CSV)</a>
      <button type="button" className="btn btn-sm" onClick={() => window.print()}>Imprimir / guardar PDF</button>
    </div>
  );
}
