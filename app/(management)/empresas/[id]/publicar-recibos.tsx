'use client';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { concluirRecibos, prepararRecibos } from '@/lib/empresas-gestao-actions';
import c from '../empresas.module.css';

/** Publicar os recibos de vencimento de um mês: o PDF vai do browser
    diretamente para o Storage, com o progresso, sem o limite de 4,5 MB de um
    pedido ao servidor. */
export function PublicarRecibos({ empresa, meses }: { empresa: string; meses: { valor: string; nome: string }[] }) {
  const router = useRouter();
  const [mes, setMes] = useState(meses[0]?.valor ?? '');
  const [ficheiro, setFicheiro] = useState<File | null>(null);
  const [progresso, setProgresso] = useState<number | null>(null);
  const [estado, setEstado] = useState<{ ok?: string; erro?: string } | null>(null);

  async function publicar(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formulario = e.currentTarget;
    if (!ficheiro) return setEstado({ erro: 'Escolha o PDF dos recibos.' });
    const cabeca = new Uint8Array(await ficheiro.slice(0, 4).arrayBuffer());
    if (String.fromCharCode(...cabeca) !== '%PDF') return setEstado({ erro: 'O ficheiro tem de ser um PDF.' });
    setEstado(null);
    setProgresso(0);
    try {
      const p = await prepararRecibos(empresa, mes, { nome: ficheiro.name, mime: 'application/pdf', tamanho: ficheiro.size });
      if ('erro' in p) return setEstado({ erro: p.erro });
      const carregou = await new Promise<boolean>((resolve) => {
        const x = new XMLHttpRequest();
        x.open('PUT', p.url);
        x.setRequestHeader('Content-Type', 'application/pdf');
        x.setRequestHeader('x-upsert', 'false');
        x.upload.onprogress = (ev) => { if (ev.lengthComputable) setProgresso(ev.loaded / ev.total); };
        x.onload = () => resolve(x.status >= 200 && x.status < 300);
        x.onerror = () => resolve(false);
        x.send(ficheiro);
      });
      const r = await concluirRecibos(empresa, mes, p.ref, p.id, !carregou);
      setEstado(r);
      if (r.ok) { setFicheiro(null); formulario.reset(); router.refresh(); }
    } catch {
      setEstado({ erro: 'Sem ligação. Tente novamente.' });
    } finally {
      setProgresso(null);
    }
  }

  return (
    <form onSubmit={publicar} className="pilha pilha-3">
      <div className={c.campos}>
        <label className="campo"><span>Mês</span>
          <select className="entrada" required value={mes} onChange={(e) => setMes(e.target.value)} disabled={progresso != null}>
            {meses.map((m) => <option key={m.valor} value={m.valor}>{m.nome}</option>)}
          </select>
        </label>
        <label className="campo"><span>PDF com os recibos</span>
          <input type="file" accept="application/pdf" required disabled={progresso != null}
                 onChange={(e) => { setFicheiro(e.target.files?.[0] ?? null); setEstado(null); }} />
        </label>
      </div>
      <small className="pequeno suave">Publicar de novo o mesmo mês substitui o ficheiro anterior. O cliente recebe um email.</small>
      {progresso != null && (
        <progress max={1} value={progresso} style={{ inlineSize: '100%' }} aria-label="Progresso do envio" />
      )}
      {estado?.erro && <p className="aviso aviso-critico" role="alert">{estado.erro}</p>}
      {estado?.ok && <p className="aviso aviso-positivo" role="status">{estado.ok}</p>}
      <div className={c.acoes}>
        <button className="btn btn-sm" type="submit" disabled={progresso != null}>
          {progresso != null ? `A publicar… ${Math.round(progresso * 100)}%` : 'Publicar recibos'}
        </button>
      </div>
    </form>
  );
}
