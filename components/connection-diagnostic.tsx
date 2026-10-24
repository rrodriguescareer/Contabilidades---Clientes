'use client';
import { useState } from 'react';

/* Mede o caminho completo até ao Supabase a partir desta aplicação.
   Serve para confirmar que as funções correm mesmo ao lado da base de dados. */
export default function DiagnosticoLigacao() {
  const [ocupado, definirOcupado] = useState(false);
  const [resultado, definirResultado] = useState('');

  async function medir() {
    definirOcupado(true);
    const inicio = performance.now();
    try {
      const resposta = await fetch('/api/diagnostico', { cache: 'no-store' });
      if (!resposta.ok) throw new Error();
      const dados = await resposta.json();
      if (typeof dados.authentication_ms !== 'number') throw new Error();
      definirResultado(
        `Pedido completo ${Math.round(performance.now() - inicio)} ms · autorização no servidor ${dados.authentication_ms} ms · região ${dados.region}`,
      );
    } catch {
      definirResultado('Não foi possível medir a ligação.');
    } finally {
      definirOcupado(false);
    }
  }

  return (
    <div className="pilha pilha-2">
      <button className="btn btn-secundario btn-sm" disabled={ocupado} onClick={medir} style={{ justifySelf: 'start' }}>
        {ocupado ? 'A medir…' : 'Medir tempo de ligação'}
      </button>
      {resultado && (
        <p role="status" className="micro tenue">
          {resultado}
        </p>
      )}
    </div>
  );
}
