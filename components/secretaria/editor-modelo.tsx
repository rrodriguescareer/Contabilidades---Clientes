'use client';
import { useRef, useState } from 'react';
import { Submeter } from '@/components/forms';
import { guardarModelo, reporModelo } from '@/lib/secretaria-actions';
import { VARIAVEIS, aplicar, comporEmail, type PendenciaAberta } from '@/lib/secretaria';
import s from './secretaria.module.css';

const EXEMPLO: PendenciaAberta[] = [
  { id: '1', periodo: '2026-10-01', tipo: 'FT', descricao: 'Fornecedor Exemplo, Lda', numero: 'FT 2026/142', data_documento: '2026-10-15', valor_cents: 12345, banco: null },
  { id: '2', periodo: '2026-10-01', tipo: 'EB', descricao: 'Extrato de outubro', numero: null, data_documento: null, valor_cents: null, banco: 'Banco Exemplo' },
];

/* Editar o texto de um email, com as variáveis à mão e a pré-visualização. */
export function EditorModelo({ titulo, tipo, empresa, assunto, corpo, voltar, proprio, nomeEmpresa = 'Empresa Exemplo, Lda' }: {
  titulo: string; tipo: string; empresa?: string; assunto: string; corpo: string; voltar: string; proprio?: boolean; nomeEmpresa?: string;
}) {
  const [a, setA] = useState(assunto);
  const [c, setC] = useState(corpo);
  const [ver, setVer] = useState(false);
  const area = useRef<HTMLTextAreaElement>(null);

  const inserir = (chave: string) => {
    const t = area.current;
    const marca = `{{${chave}}}`;
    if (!t) return setC((x) => x + marca);
    const [i, f] = [t.selectionStart, t.selectionEnd];
    setC(c.slice(0, i) + marca + c.slice(f));
    requestAnimationFrame(() => { t.focus(); t.setSelectionRange(i + marca.length, i + marca.length); });
  };
  const email = comporEmail({ tipo, assunto: a, corpo: c, empresa: nomeEmpresa, contacto: 'Ana Silva', pendencias: EXEMPLO, diaLimite: '2026-11-10' });

  return (
    <div className={s.bloco}>
      <div className={s.blocoTitulo}>
        <h3>{titulo}</h3>
        {empresa && <span className={proprio ? 'etiqueta etiqueta-acao' : 'etiqueta'}>{proprio ? 'Modelo deste cliente' : 'A usar o modelo do gabinete'}</span>}
      </div>
      <form action={guardarModelo} className="pilha pilha-3">
        <input type="hidden" name="tipo" value={tipo} />
        <input type="hidden" name="voltar" value={voltar} />
        {empresa && <input type="hidden" name="empresa" value={empresa} />}
        <label className="campo">
          <span>Assunto</span>
          <input name="assunto" className="entrada" maxLength={250} value={a} onChange={(e) => setA(e.target.value)} required />
        </label>
        <label className="campo">
          <span>Texto do email</span>
          <textarea ref={area} name="corpo" className="entrada" rows={12} maxLength={8000} value={c} onChange={(e) => setC(e.target.value)} required />
        </label>
        <div className={s.variaveis} aria-label="Inserir variável">
          {VARIAVEIS.map((v) => <button type="button" key={v.chave} onClick={() => inserir(v.chave)}>{v.nome}</button>)}
        </div>
        {ver && (
          <div className={s.previsao}>
            <h4>{aplicar(email.assunto, {})}</h4>
            {email.paragrafos.map((p, i) => (typeof p === 'string'
              ? <p key={i}>{p}</p>
              : <div key={i}><strong>{p.lista}</strong><ol>{p.itens.map((x) => <li key={x}>{x}</li>)}</ol></div>))}
          </div>
        )}
        <div className={s.linhaBotoes}>
          <button type="button" className="btn btn-secundario btn-sm" onClick={() => setVer((x) => !x)}>{ver ? 'Esconder' : 'Pré-visualizar'}</button>
          <Submeter className="btn btn-sm">Guardar modelo</Submeter>
        </div>
      </form>
      {empresa && proprio && (
        <form action={reporModelo}>
          <input type="hidden" name="tipo" value={tipo} />
          <input type="hidden" name="voltar" value={voltar} />
          <input type="hidden" name="empresa" value={empresa} />
          <button className="btn-texto pequeno" type="submit">Voltar ao modelo do gabinete</button>
        </form>
      )}
    </div>
  );
}
