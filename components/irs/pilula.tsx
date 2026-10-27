import { estadoDe, ROTULOS } from '@/lib/fluxo';
import e from './gabinete.module.css';

/** O estado de um processo, com a cor de quem tem a vez. */
export function Pilula({ estado }: { estado: string }) {
  const est = estadoDe(estado);
  return (
    <span className={e.pilula} data-espera={est?.espera} data-desvio={est?.desvio}>
      {ROTULOS[estado] || estado}
    </span>
  );
}
