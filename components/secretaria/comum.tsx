import Link from 'next/link';
import { Submeter } from '@/components/forms';
import { iniciarProcesso } from '@/lib/secretaria-actions';
import type { Periodo } from '@/lib/secretaria';
import { Dialogo } from './dialogo';
import s from './secretaria.module.css';

export function Numero({ rotulo, valor, nota, tom, href }: { rotulo: string; valor: React.ReactNode; nota?: string; tom?: 'atencao' | 'critico'; href?: string }) {
  const corpo = <><span>{rotulo}</span><strong>{valor}</strong>{nota && <small>{nota}</small>}</>;
  return href
    ? <Link prefetch={false} href={href} className={s.numero} data-tom={tom}>{corpo}</Link>
    : <div className={s.numero} data-tom={tom}>{corpo}</div>;
}

export function Faixa({ tom, children, acao }: { tom?: 'atencao' | 'positivo'; children: React.ReactNode; acao?: React.ReactNode }) {
  return (
    <div className={s.faixa} data-tom={tom}>
      <span className={s.faixaTexto}>{children}</span>
      {acao}
    </div>
  );
}

export function Progresso({ parte, total }: { parte: number; total: number }) {
  if (!total) return <span className="tenue">—</span>;
  return (
    <div className={s.progresso}>
      <span>{parte} de {total} recebidos</span>
      <div className={s.barra}><i style={{ inlineSize: `${Math.round((parte / total) * 100)}%` }} /></div>
    </div>
  );
}

/** Todos / Mensal / Trimestral, e as setas do período. */
export function SeletorPeriodo({ periodo, caminho, manter = {} }: { periodo: Periodo; caminho: string; manter?: Record<string, string | undefined> }) {
  const url = (modo: string, p?: string) => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(manter)) if (v) q.set(k, v);
    if (modo !== 'todos') q.set('modo', modo);
    if (p) q.set('p', p);
    const t = q.toString();
    return t ? `${caminho}${caminho.includes('?') ? '&' : '?'}${t}` : caminho;
  };
  return (
    <div className={s.periodo}>
      <div className={s.segmento} role="group" aria-label="Período">
        {[['todos', 'Todos'], ['mensal', 'Mensal'], ['trimestral', 'Trimestral']].map(([m, n]) => (
          <Link prefetch={false} key={m} href={url(m)} aria-current={periodo.modo === m ? 'true' : undefined}>{n}</Link>
        ))}
      </div>
      {periodo.anterior && (
        <div className={s.passo}>
          <Link prefetch={false} href={url(periodo.modo, periodo.anterior)} aria-label="Período anterior">‹</Link>
          <span>{periodo.rotulo}</span>
          <Link prefetch={false} href={url(periodo.modo, periodo.seguinte)} aria-label="Período seguinte">›</Link>
        </div>
      )}
    </div>
  );
}

export function IniciarProcesso({ empresa, limite, voltar, rotulo = 'Iniciar processo', classe = 'btn btn-sm', aprovar }: { empresa: string; limite: string; voltar: string; rotulo?: string; classe?: string; aprovar: string }) {
  return (
    <Dialogo rotulo={rotulo} classe={classe} titulo="Iniciar processo">
      <form action={iniciarProcesso} className="pilha pilha-4">
        <input type="hidden" name="empresa" value={empresa} />
        <input type="hidden" name="voltar" value={voltar} />
        <label className="campo">
          <span>Dia limite para a entrega</span>
          <input type="date" name="limite" className="entrada" defaultValue={limite} required />
          <small>Fica fixo: se o cliente precisar de mais tempo, cancele e inicie outro processo.</small>
        </label>
        <div className={s.opcoes}>
          <label className={s.opcao}>
            <input type="radio" name="quando" value="ja" defaultChecked />
            <div><strong>Enviar já</strong><span>{aprovar === 'nenhum' ? 'O pedido sai de imediato.' : 'O pedido fica à espera da sua aprovação em «Por aprovar».'}</span></div>
          </label>
          <label className={s.opcao}>
            <input type="radio" name="quando" value="proximo" />
            <div><strong>Esperar pelo próximo envio</strong><span>Sai na próxima data do calendário de insistências.</span></div>
          </label>
        </div>
        <p className="pequeno suave">O processo inclui as pendências em acompanhamento e termina quando não faltar nada, no dia limite ou se o cancelar.</p>
        <div className={s.linhaBotoes}><Submeter className="btn" aDecorrer="A iniciar…">Iniciar processo</Submeter></div>
      </form>
    </Dialogo>
  );
}
