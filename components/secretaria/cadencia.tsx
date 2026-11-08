'use client';
import { useState } from 'react';
import { DIAS_SEMANA, type Cadencia } from '@/lib/secretaria';
import s from './secretaria.module.css';

/* O calendário das insistências: dias da semana, de N em N dias ou dias úteis. */
export function CamposCadencia({ inicial }: { inicial?: Cadencia | null }) {
  const [modo, setModo] = useState<string>(inicial?.modo ?? 'corridos');
  const intervalo = inicial && inicial.modo !== 'semana' ? inicial.intervalo : 7;
  const hora = inicial && inicial.modo !== 'semana' ? inicial.hora : 9;
  const dias = inicial?.modo === 'semana' ? inicial.dias : { 1: 9 } as Record<string, number>;
  return (
    <div className="pilha pilha-3">
      <label className="campo">
        <span>Quando enviar</span>
        <select name="modo" className="entrada" value={modo} onChange={(e) => setModo(e.target.value)}>
          <option value="corridos">Dias corridos</option>
          <option value="uteis">Dias úteis</option>
          <option value="semana">Dias da semana</option>
        </select>
      </label>
      {modo === 'semana' ? (
        <div className={s.grelhaDias}>
          {DIAS_SEMANA.map(([k, nome]) => (
            <label className="campo" key={k}>
              <span>{nome}</span>
              <select name={`dia_${k}`} className="entrada" defaultValue={dias[k] ?? ''}>
                <option value="">Não</option>
                {Array.from({ length: 14 }, (_, i) => i + 7).map((h) => <option key={h} value={h}>{String(h).padStart(2, '0')}:00</option>)}
              </select>
            </label>
          ))}
        </div>
      ) : (
        <div className={s.campos}>
          <label className="campo">
            <span>De quantos em quantos dias</span>
            <input name="intervalo" type="number" min={1} max={60} className="entrada" defaultValue={intervalo} />
          </label>
          <label className="campo">
            <span>Hora (Lisboa)</span>
            <select name="hora" className="entrada" defaultValue={hora}>
              {Array.from({ length: 14 }, (_, i) => i + 7).map((h) => <option key={h} value={h}>{String(h).padStart(2, '0')}:00</option>)}
            </select>
          </label>
        </div>
      )}
    </div>
  );
}
