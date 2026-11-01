'use client';
import { useEffect, useState, useTransition } from 'react';
import { decidirDesistencia, desistenciaDoProcesso, type PedidoDesistencia } from '@/lib/irs-actions';
import e from './gabinete.module.css';

const data = (iso: string) =>
  new Date(iso).toLocaleString('pt-PT', { timeZone: 'Europe/Lisbon', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

/** O pedido de desistência do cliente, por cima do processo, para decidir. */
export function Desistencia({ processo, aoMudar }: { processo: string; aoMudar: () => void }) {
  const [pedido, setPedido] = useState<PedidoDesistencia | null>(null);
  const [resposta, setResposta] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [aCorrer, correr] = useTransition();

  useEffect(() => {
    let vivo = true;
    desistenciaDoProcesso(processo).then((p) => { if (vivo) setPedido(p); }).catch(() => {});
    return () => { vivo = false; };
  }, [processo]);

  if (!pedido) return null;
  const decidir = (aceite: boolean) => correr(async () => {
    setErro(null);
    const r = await decidirDesistencia(pedido.id, aceite, resposta, processo);
    if (!r.ok) return setErro(r.erro || 'Não foi possível guardar.');
    setPedido(null);
    aoMudar();
  });

  return (
    <section className={e.cartao} role="alert" style={{ borderInlineStart: '4px solid var(--critico)' }}>
      <h3 style={{ margin: 0 }}>Pedido de desistência</h3>
      <p className="pequeno">
        Pedido a {data(pedido.criado_em)} — {pedido.dentro_do_prazo
          ? 'dentro dos 14 dias de livre resolução'
          : 'fora dos 14 dias de livre resolução'} (contrato a {data(pedido.contratado_em)}).
      </p>
      {pedido.motivo && <p className="pequeno"><strong>Motivo:</strong> {pedido.motivo}</p>}
      <label className="campo">
        <span>Nota para o cliente (opcional)</span>
        <textarea className="entrada" rows={2} maxLength={2000} value={resposta} onChange={(ev) => setResposta(ev.target.value)} />
      </label>
      {erro && <p className="aviso aviso-critico">{erro}</p>}
      <div className="linha">
        <button type="button" className="btn btn-critico btn-sm" disabled={aCorrer} onClick={() => decidir(true)}>Aceitar e encerrar o processo</button>
        <button type="button" className="btn btn-secundario btn-sm" disabled={aCorrer} onClick={() => decidir(false)}>Recusar</button>
      </div>
      <p className="micro tenue">Se houver reembolso, faça-o depois no separador Pagamento: fica com a nota de crédito no Cegid.</p>
    </section>
  );
}
