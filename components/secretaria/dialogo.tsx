'use client';
import { useEffect, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import s from './secretaria.module.css';

/* Um botão que abre uma janela. Fecha sozinha quando a ação termina: cada ação
   devolve à mesma página com um aviso novo no endereço. */
export function Dialogo({ rotulo, classe = 'btn btn-secundario btn-sm', titulo, largo, children }: {
  rotulo: React.ReactNode; classe?: string; titulo: string; largo?: boolean; children: React.ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const procura = useSearchParams().toString();
  useEffect(() => { if (ref.current?.open) ref.current.close(); }, [procura]);
  return (
    <>
      <button type="button" className={classe} onClick={() => ref.current?.showModal()}>{rotulo}</button>
      <dialog ref={ref} className={s.dialogo} data-largo={largo ? 'true' : undefined} aria-label={titulo}
              onClick={(e) => { if (e.target === ref.current) ref.current?.close(); }}>
        <div className={s.dialogoCaixa}>
          <div className={s.dialogoTopo}>
            <h3>{titulo}</h3>
            <button type="button" className={s.fechar} aria-label="Fechar" onClick={() => ref.current?.close()}>×</button>
          </div>
          {children}
        </div>
      </dialog>
    </>
  );
}
