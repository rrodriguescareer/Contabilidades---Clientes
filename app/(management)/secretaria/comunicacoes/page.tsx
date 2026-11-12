import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { IniciarProcesso } from '@/components/secretaria/comum';
import { MOTIVOS, PRAZOS, dataHoraPt, dataPt, hojeLisboa, limiteSugerido, respostaTexto, type ClienteResumo } from '@/lib/secretaria';
import { TODOS, clientesResumo } from '@/lib/secretaria-dados';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Comunicações · Secretária' };

function porque(c: ClienteResumo) {
  if (!c.tem_contacto) return 'Sem contacto principal';
  if (c.resposta === 'sem_resposta') return `${c.processo?.insistencias ? `${c.processo.insistencias} insistência${c.processo.insistencias === 1 ? '' : 's'} sem resposta` : 'Pedido sem resposta'}`;
  if (c.ultimo_motivo && !c.processo) return `O último processo terminou: ${MOTIVOS[c.ultimo_motivo]?.toLowerCase()}`;
  return 'Ainda não foi pedido';
}

export default async function Comunicacoes({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const avisos = await searchParams;
  const [clientes, { data: definicoes }] = await Promise.all([
    clientesResumo(client, TODOS),
    client.from('secretaria_definicoes').select('aprovar,dia_limite').maybeSingle(),
  ]);
  const semResposta = clientes.filter((c) => c.em_falta_total > 0 && (c.resposta === 'sem_resposta' || c.resposta === 'nao_obtida' || !c.processo))
    .sort((a, b) => (b.sem_resposta_dias ?? -1) - (a.sem_resposta_dias ?? -1));
  const emCurso = clientes.filter((c) => c.processo).sort((a, b) => String(a.processo!.proximo_envio ?? '9').localeCompare(String(b.processo!.proximo_envio ?? '9')));
  const limite = limiteSugerido(definicoes?.dia_limite ?? 10, [hojeLisboa().slice(0, 7)]);

  return (
    <div className={s.pagina}>
      <Avisos erro={avisos.erro} mensagem={avisos.mensagem} />
      <div className={s.intro}><p>Quem está por responder, e o que a Secretária vai enviar a seguir.</p></div>

      <section className="pilha pilha-3">
        <h3>Comunicações sem resposta</h3>
        {semResposta.length === 0 ? (
          <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Ninguém está à espera de si</strong><span>Todos os clientes com documentos em falta responderam ou estão a ser acompanhados.</span></div>
        ) : (
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Cliente</th><th>Pendências</th><th>Sem resposta há</th><th>Porquê</th><th>Prazo</th><th className={s.direita}>Ação</th></tr></thead>
              <tbody>
                {semResposta.map((c) => (
                  <tr key={c.id}>
                    <td data-rotulo=""><Link prefetch={false} className={s.nome} href={`/secretaria/clientes/${c.id}`}>{c.nome}</Link><span className={s.segundo}>NIF {c.nif}</span></td>
                    <td data-rotulo="Pendências">{c.em_falta_total}</td>
                    <td data-rotulo="Sem resposta há" className={s.nowrap}>{c.sem_resposta_dias != null ? `${c.sem_resposta_dias} dias` : '—'}</td>
                    <td data-rotulo="Porquê">{porque(c)}</td>
                    <td data-rotulo="Prazo">{c.prazo ? <span className={PRAZOS[c.prazo].classe}>{PRAZOS[c.prazo].nome}</span> : '—'}</td>
                    <td data-rotulo="" className={s.direita}>
                      {c.processo || !c.tem_contacto
                        ? <Link prefetch={false} className={s.acaoPequena} href={`/secretaria/clientes/${c.id}${c.tem_contacto ? '' : '?aba=contactos'}`}>Abrir</Link>
                        : <IniciarProcesso empresa={c.id} limite={limite} voltar="/secretaria/comunicacoes" aprovar={definicoes?.aprovar ?? 'primeiro'} classe={s.acaoPequena} />}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="pilha pilha-3">
        <h3>Comunicações automáticas em curso</h3>
        {emCurso.length === 0 ? (
          <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Sem processos em curso</strong><span>Inicie um processo a partir da ficha do cliente.</span></div>
        ) : (
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Cliente</th><th>Em falta</th><th>Próximo lembrete</th><th>Dia limite</th><th>Resposta</th></tr></thead>
              <tbody>
                {emCurso.map((c) => (
                  <tr key={c.id}>
                    <td data-rotulo=""><Link prefetch={false} className={s.nome} href={`/secretaria/clientes/${c.id}`}>{c.nome}</Link></td>
                    <td data-rotulo="Em falta">{c.em_falta_total}</td>
                    <td data-rotulo="Próximo lembrete" className={s.nowrap}>{c.processo!.proximo_envio ? dataHoraPt(c.processo!.proximo_envio) : c.automatico ? 'Não há mais envios até ao limite' : 'Envio automático desligado'}</td>
                    <td data-rotulo="Dia limite" className={s.nowrap}>{dataPt(c.processo!.dia_limite)} {c.prazo === 'fora' && <span className="etiqueta etiqueta-critico">Em atraso</span>}</td>
                    <td data-rotulo="Resposta" className={s.nowrap}>{respostaTexto(c)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
