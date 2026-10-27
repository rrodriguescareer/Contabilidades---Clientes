'use client';
import { useState, useTransition } from 'react';
import { criarFichaCegid, emitirFaturaCegid, guardarCredenciaisCegid, testarCegid } from '@/lib/irs-actions';
import e from './gabinete.module.css';

/* As credenciais são escritas aqui e guardadas cifradas. Nunca voltam ao
   ecrã: o que se mostra é se existem e se a ligação responde. */
export function Integracoes({ configurado, origem }:
  { configurado: boolean; origem: 'ambiente' | 'gabinete' | 'nenhuma' }) {
  const [estado, setEstado] = useState<{ ok?: boolean; texto?: string }>({});
  const [aCorrer, comecar] = useTransition();

  return (
    <section className={e.bloco}>
      <h2>Cegid Business</h2>
      <p>
        {origem === 'ambiente'
          ? 'Credenciais nas variáveis de ambiente da Vercel. O que escrever aqui não as substitui — para as trocar, trocam-se lá.'
          : configurado
            ? 'Credenciais guardadas aqui, cifradas. A autorização é renovada sozinha.'
            : 'Ainda sem credenciais. Encontra-as no Cegid, em Dados API.'}
      </p>

      <form
        action={(form) =>
          comecar(async () => {
            const r = await guardarCredenciaisCegid(form);
            setEstado({ ok: r.ok, texto: r.ok ? r.aviso : r.erro });
          })
        }
        style={{ display: 'grid', gap: '.6rem', maxWidth: '32rem' }}
      >
        <label style={{ display: 'grid', gap: '.3rem', fontSize: '.8rem' }}>
          Identificador
          <input name="identificador" required autoComplete="off"
                 placeholder={configurado ? 'Guardado — escreva para substituir' : ''} />
        </label>
        <label style={{ display: 'grid', gap: '.3rem', fontSize: '.8rem' }}>
          Segredo
          <input name="segredo" type="password" required autoComplete="new-password" />
        </label>

        <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
          <button type="submit" className="btn" disabled={aCorrer}>
            {aCorrer ? 'A guardar…' : 'Guardar e testar'}
          </button>
          {configurado && (
            <button type="button" className="btn btn-secundario" disabled={aCorrer}
                    onClick={() => comecar(async () => {
                      const r = await testarCegid();
                      setEstado({ ok: r.ok, texto: r.ok ? r.aviso : r.erro });
                    })}>
              Testar ligação
            </button>
          )}
        </div>
      </form>

      {estado.texto && (
        <p className={estado.ok ? 'aviso-positivo' : 'aviso-critico'}>{estado.texto}</p>
      )}
    </section>
  );
}

/** Os dois botões de teste, dentro de um processo. */
export function TestesCegid({ processo }: { processo: string }) {
  const [estado, setEstado] = useState<{ ok?: boolean; texto?: string }>({});
  const [aCorrer, comecar] = useTransition();

  const correr = (accao: (p: string) => Promise<{ ok: boolean; erro?: string; aviso?: string; detalhe?: string }>) =>
    comecar(async () => {
      const r = await accao(processo);
      setEstado({
        ok: r.ok,
        texto: r.ok ? [r.aviso, r.detalhe].filter(Boolean).join(' · ') : r.erro,
      });
    });

  return (
    <section className={e.bloco}>
      <h2>Cegid</h2>
      <p>Para testar a API. A fatura fica em preparação — o fecho é feito no Cegid.</p>
      <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
        <button type="button" className="btn btn-secundario" disabled={aCorrer}
                onClick={() => correr(criarFichaCegid)}>
          Criar ficha de cliente
        </button>
        <button type="button" className="btn btn-secundario" disabled={aCorrer}
                onClick={() => correr(emitirFaturaCegid)}>
          Emitir fatura-recibo
        </button>
      </div>
      {estado.texto && (
        <p className={estado.ok ? 'aviso-positivo' : 'aviso-critico'}>{estado.texto}</p>
      )}
    </section>
  );
}
