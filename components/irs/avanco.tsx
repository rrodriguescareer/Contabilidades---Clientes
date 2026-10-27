'use client';
import { useRouter } from 'next/navigation';
import { useEffect, useState, useTransition } from 'react';
import { avancarProcesso, prontidaoDoProcesso } from '@/lib/irs-actions';
import { FASES, LINHA, PASSOS, QUEM, estadoDe, posicao, type Prontidao } from '@/lib/fluxo';
import e from './gabinete.module.css';

/* Isto era uma caixa com botões e nada mais: não se via onde o processo estava
   nem o que faltava para o deixar seguir. Agora tem três partes — a régua das
   fases, a prontidão (a mesma lista que o cliente vê) e as ações, com o passo
   seguinte em destaque e os desvios e recuos à parte. */
export function Avanco({
  processo, estado, aoMudar, prontidaoInicial,
}: {
  processo: string; estado: string; aoMudar?: () => void;
  /* Quem já tem a lista passa-a e poupa a ida ao servidor. */
  prontidaoInicial?: Prontidao[];
}) {
  const router = useRouter();
  const [erro, setErro] = useState<string | null>(null);
  const [nota, setNota] = useState('');
  const [valor, setValor] = useState('');
  const [sentido, setSentido] = useState('refund');
  const [prontidao, setProntidao] = useState<Prontidao[]>(prontidaoInicial || []);
  const [aCorrer, comecar] = useTransition();

  useEffect(() => {
    if (prontidaoInicial) return;
    let vivo = true;
    prontidaoDoProcesso(processo)
      .then(({ dados }) => {
        if (vivo && Array.isArray(dados)) setProntidao(dados as Prontidao[]);
      })
      /* A prontidão é informação a mais: se falhar, o fluxo continua a servir. */
      .catch(() => {});
    return () => { vivo = false; };
  }, [processo, estado, prontidaoInicial]);

  const actual = estadoDe(estado);
  const { indice, fase } = posicao(estado);
  const passos = PASSOS[estado] || [];
  const faseActual = FASES.findIndex((f) => f.id === fase);
  const avanco = passos.filter((p) => p.tom === 'avancar');
  const outros = passos.filter((p) => p.tom !== 'avancar');
  // Quando o servidor a manda, é essa que vale: depois de avançar, o refresh
  // traz a lista nova e o estado local ficava com a antiga.
  const lista = prontidaoInicial ?? prontidao;
  const pendentes = lista.filter((p) => p.estado !== 'ok');

  const pedir = (destino: string) =>
    comecar(async () => {
      setErro(null);
      const r = await avancarProcesso(processo, destino, nota, valor, sentido);
      if (!r.ok) { setErro(r.erro || 'Não foi possível avançar.'); return; }
      setNota(''); setValor('');
      aoMudar?.();
      router.refresh();
    });

  return (
    <section className={e.bloco}>
      <div className="linha-entre">
        <h2>Fluxo do processo</h2>
        <span className="selo-espera" data-espera={actual?.espera}>
          {QUEM[actual?.espera || 'gabinete']}
        </span>
      </div>

      {/* A régua: as quatro fases e, por baixo, os passos da linha principal. */}
      <ol className="fases fases-compactas">
        {FASES.map((f, j) => (
          <li key={f.id} data-estado={j < faseActual ? 'feito' : j === faseActual ? 'atual' : 'por-vir'}>
            <strong>{f.titulo}</strong>
            <span>
              {LINHA.filter((x) => x.fase === f.id)
                .map((x) => x.curto)
                .join(' · ')}
            </span>
          </li>
        ))}
      </ol>
      <p className="regua-passo">
        Passo {indice + 1} de {LINHA.length} · <strong>{actual?.titulo || estado}</strong>
        {actual?.desvio ? ' (desvio)' : ''}
      </p>

      {/* A prontidão. Só o que não está pronto: o resto é ruído a conferir. */}
      {pendentes.length > 0 && (
        <ul className="prontidao prontidao-compacta">
          {pendentes.map((p) => (
            <li key={p.chave} data-estado={p.estado}>
              <span className="marca-pronto" aria-hidden="true" />
              <div>
                <strong>{p.rotulo}</strong>
                <p className="suave">{p.detalhe}</p>
              </div>
            </li>
          ))}
        </ul>
      )}
      {lista.length > 0 && pendentes.length === 0 && (
        <p className="aviso-positivo">Prontidão completa: dados, senha, rendimentos e pagamento.</p>
      )}

      {passos.length === 0 ? (
        <p className="suave">Não há mais passos a partir deste estado.</p>
      ) : (
        <>
          {/* Só se pede o valor onde ele existe: na entrega. */}
          {estado === 'submitting' && (
            <div className="grelha-campos">
              <label className="campo">
                <span className="rotulo">Valor apurado</span>
                <input className="entrada" value={valor} onChange={(ev) => setValor(ev.target.value)}
                       inputMode="decimal" placeholder="0,00" />
              </label>
              <label className="campo">
                <span className="rotulo">Sentido</span>
                <select className="entrada" value={sentido} onChange={(ev) => setSentido(ev.target.value)}>
                  <option value="refund">A reembolsar</option>
                  <option value="payment">A pagar</option>
                </select>
              </label>
            </div>
          )}

          <label className="campo">
            <span className="rotulo">Nota para o cliente (opcional)</span>
            <textarea className="entrada" rows={2} value={nota}
                      onChange={(ev) => setNota(ev.target.value)} maxLength={5000}
                      placeholder="Sem nota, o cliente recebe a explicação padrão do passo." />
          </label>

          {erro && <p className="aviso-critico">{erro}</p>}

          <div className="acoes-fluxo">
            {avanco.map((p, i) => (
              <button key={p.destino} type="button"
                      className={i === 0 ? 'btn' : 'btn btn-secundario'}
                      disabled={aCorrer} onClick={() => pedir(p.destino)}>
                {aCorrer ? 'A guardar…' : p.rotulo}
              </button>
            ))}
            {outros.length > 0 && (
              <span className="acoes-outras">
                {outros.map((p) => (
                  <button key={p.destino} type="button"
                          className={p.tom === 'desvio' ? 'btn-texto btn-desvio' : 'btn-texto'}
                          disabled={aCorrer} onClick={() => pedir(p.destino)}>
                    {p.rotulo}
                  </button>
                ))}
              </span>
            )}
          </div>
        </>
      )}
    </section>
  );
}
