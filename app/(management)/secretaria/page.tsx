import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { Icone } from '@/components/navegacao';
import { Faixa, Numero } from '@/components/secretaria/comum';
import { PRAZOS, dataHoraPt, respostaTexto } from '@/lib/secretaria';
import { TODOS, clientesResumo } from '@/lib/secretaria-dados';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Secretária' };

type Painel = {
  recebidos: number; recebidos_antes: number; em_falta: number; por_aprovar: number; falharam: number; por_identificar: number;
  processos: number; lembretes_hoje: number; saem_hoje: number; sem_processo: number; sem_contacto: number;
  atividade: { seq: number; quando: string; acao: string; autor: string; empresa: string | null; detalhe: string | null; company_id: string | null }[];
};

const plural = (n: number, um: string, varios: string) => (n === 1 ? `1 ${um}` : `${n} ${varios}`);
const ORDEM: Record<string, number> = { fora: 0, em_risco: 1, apertado: 2, em_dia: 3 };

export default async function PainelSecretaria({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const avisos = await searchParams;
  const [{ data: bruto }, clientes] = await Promise.all([
    client.rpc('secretaria_painel'),
    clientesResumo(client, TODOS),
  ]);
  const p = bruto as Painel;

  const tarefas = [
    p.falharam > 0 && { tom: 'critico', icone: 'sino', titulo: `${plural(p.falharam, 'email falhou', 'emails falharam')}`, texto: 'Veja o motivo e tente novamente.', href: '/secretaria/aprovar', botao: 'Rever' },
    p.por_aprovar > 0 && { tom: 'atencao', icone: 'ficha', titulo: `${plural(p.por_aprovar, 'pedido aguarda', 'pedidos aguardam')} a sua aprovação`, texto: 'Nenhum destes emails sai sem a sua decisão.', href: '/secretaria/aprovar', botao: 'Aprovar' },
    p.sem_contacto > 0 && { tom: 'atencao', icone: 'pessoas', titulo: `${plural(p.sem_contacto, 'cliente', 'clientes')} sem contacto principal`, texto: 'Sem contacto não é possível pedir documentos.', href: '/secretaria/clientes?f=pendencias', botao: 'Ver' },
    p.por_identificar > 0 && { tom: '', icone: 'pasta', titulo: `${plural(p.por_identificar, 'documento', 'documentos')} por identificar`, texto: 'Chegaram sem pedido associado.', href: '/secretaria/identificar', botao: 'Arquivar' },
    p.sem_processo > 0 && { tom: '', icone: 'balao', titulo: `${plural(p.sem_processo, 'cliente', 'clientes')} com pendências e sem processo`, texto: 'Ainda ninguém lhes pediu estes documentos.', href: '/secretaria/comunicacoes', botao: 'Iniciar' },
  ].filter(Boolean).slice(0, 3) as { tom: string; icone: string; titulo: string; texto: string; href: string; botao: string }[];

  const atencao = clientes
    .filter((c) => c.em_falta_total > 0)
    .sort((a, b) => (ORDEM[a.prazo ?? 'em_dia'] ?? 3) - (ORDEM[b.prazo ?? 'em_dia'] ?? 3) || b.em_falta_total - a.em_falta_total)
    .slice(0, 4);

  const variacao = p.recebidos - p.recebidos_antes;
  const semNada = !p.em_falta && !p.recebidos && !p.processos;

  return (
    <div className={s.pagina}>
      <Avisos erro={avisos.erro} mensagem={avisos.mensagem} />
      <div className={s.intro}>
        <p>Peça, acompanhe e receba os documentos em falta dos clientes, sem trabalho manual de conciliação.</p>
        <div className={s.acoes}>
          <Link prefetch={false} className="btn btn-sm" href="/secretaria/clientes">Ver clientes</Link>
        </div>
      </div>

      <div className={s.numeros}>
        <Numero rotulo="Documentos recebidos" valor={p.recebidos}
                nota={`Últimos 30 dias · ${variacao === 0 ? 'igual aos 30 anteriores' : `${variacao > 0 ? '+' : ''}${variacao} face aos 30 anteriores`}`} />
        <Numero rotulo="Documentos em falta" valor={p.em_falta} tom={p.em_falta ? 'atencao' : undefined} href="/secretaria/clientes?f=pendencias"
                nota={p.processos ? plural(p.processos, 'processo em curso', 'processos em curso') : 'Sem processos em curso'} />
        <Numero rotulo="Pedidos por aprovar" valor={p.por_aprovar} href="/secretaria/aprovar" nota={p.por_aprovar ? 'Aguardam a sua decisão' : 'Nada à espera'} />
      </div>

      {p.processos > 0 && (
        <Faixa acao={<Link prefetch={false} className={s.acaoPequena} href="/secretaria/comunicacoes">Ver comunicações</Link>}>
          <Icone nome="sino" />
          <span><strong>A Secretária continua a acompanhar os pedidos.</strong> {plural(p.lembretes_hoje, 'email enviado', 'emails enviados')} hoje{p.saem_hoje ? ` · ${plural(p.saem_hoje, 'sai', 'saem')} ainda hoje` : ''}.</span>
        </Faixa>
      )}

      {semNada && (
        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h2>Como começar</h2></div>
          <div className={s.linhas}>
            {[
              ['Confirme o contacto de cada cliente', 'É o endereço para onde seguem os pedidos.'],
              ['Registe o que falta', 'Uma a uma, a partir de um Excel, ou com documentos que se repetem todos os meses.'],
              ['Inicie o processo', 'Aprova o primeiro email, e a Secretária insiste até chegar tudo.'],
            ].map(([t, n], i) => (
              <div key={t} className={s.linhaItem}>
                <span className={s.linhaIcone}>{i + 1}</span>
                <div className={s.linhaTexto}><strong>{t}</strong><span>{n}</span></div>
              </div>
            ))}
          </div>
        </section>
      )}

      <div className={s.duasIguais}>
        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h2>O que precisa de fazer agora</h2></div>
          {tarefas.length === 0 ? (
            <div className={s.vazioPequeno}><strong>Nada à sua espera</strong><span>Quando precisar de si, aparece aqui.</span></div>
          ) : (
            <div className={s.linhas}>
              {tarefas.map((t) => (
                <div key={t.titulo} className={s.linhaItem}>
                  <span className={s.linhaIcone} data-tom={t.tom}><Icone nome={t.icone} /></span>
                  <div className={s.linhaTexto}><strong>{t.titulo}</strong><span>{t.texto}</span></div>
                  <Link prefetch={false} className="btn btn-secundario btn-sm" href={t.href}>{t.botao}</Link>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className={s.bloco}>
          <div className={s.blocoTitulo}><h2>Clientes que precisam de atenção</h2><Link prefetch={false} className="pequeno" href="/secretaria/clientes">Ver todos</Link></div>
          {atencao.length === 0 ? (
            <div className={s.vazioPequeno}><strong>Todos em dia</strong><span>Nenhum cliente tem documentos em falta.</span></div>
          ) : (
            <div className={s.linhas}>
              {atencao.map((c) => (
                <Link prefetch={false} key={c.id} href={`/secretaria/clientes/${c.id}`} className={s.linhaItem}>
                  <span className={s.linhaIcone}><Icone nome="predio" /></span>
                  <div className={s.linhaTexto}><strong>{c.nome}</strong><span>{plural(c.em_falta_total, 'documento em falta', 'documentos em falta')} · {respostaTexto(c)}</span></div>
                  {c.prazo && <span className={PRAZOS[c.prazo].classe}>{PRAZOS[c.prazo].nome}</span>}
                </Link>
              ))}
            </div>
          )}
        </section>
      </div>

      <section className={s.bloco}>
        <div className={s.blocoTitulo}><h2>Atividade recente</h2><Link prefetch={false} className="pequeno" href="/secretaria/auditoria">Ver auditoria</Link></div>
        {p.atividade.length === 0 ? (
          <div className={s.vazioPequeno}><strong>Ainda sem atividade</strong><span>Cada pedido, resposta e decisão fica registado aqui.</span></div>
        ) : (
          <div>
            {p.atividade.map((a) => (
              <div key={a.seq} className={s.atividade}>
                <strong>{a.acao}{a.empresa ? ` · ${a.empresa}` : ''}</strong>
                <span>{dataHoraPt(a.quando)} · {a.autor}{a.detalhe ? ` · ${a.detalhe}` : ''}</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
