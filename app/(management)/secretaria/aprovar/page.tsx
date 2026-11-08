import Link from 'next/link';
import { ownerSession } from '@/lib/auth';
import { Avisos } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { Faixa } from '@/components/secretaria/comum';
import { decidirEnvio, repetirEnvio } from '@/lib/secretaria-actions';
import { html } from '@/lib/email';
import { ESTADOS_ENVIO, comporEmail, dataHoraPt, type PendenciaAberta } from '@/lib/secretaria';
import s from '@/components/secretaria/secretaria.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Por aprovar · Secretária' };

type Envio = { id: string; company_id: string; processo_id: string; tipo: string; estado: string; assunto: string; corpo: string; criado_em: string; enviado_em: string | null; erro: string | null; pendencias: number; empresa: { name: string; nif: string } | null };
const CAMPOS = 'id,company_id,processo_id,tipo,estado,assunto,corpo,criado_em,enviado_em,erro,pendencias,empresa:companies(name,nif)';

export default async function PorAprovar({ searchParams }: { searchParams: Promise<{ e?: string; erro?: string; mensagem?: string }> }) {
  const { client } = await ownerSession();
  const pedido = await searchParams;
  const [{ data: fila }, { data: falhados }, { data: recentes }] = await Promise.all([
    client.from('secretaria_envios').select(CAMPOS).eq('estado', 'por_aprovar').order('criado_em').limit(100),
    client.from('secretaria_envios').select(CAMPOS).eq('estado', 'falhou').order('criado_em', { ascending: false }).limit(20),
    client.from('secretaria_envios').select(CAMPOS).in('estado', ['enviado', 'rejeitado']).order('criado_em', { ascending: false }).limit(8),
  ]);
  const lista = (fila ?? []) as unknown as Envio[];
  const atual = lista.find((x) => x.id === pedido.e) ?? lista[0];

  let previa: { html: string; assunto: string; para: string; cc: string[] } | null = null;
  if (atual) {
    const [{ data: contactos }, { data: pendencias }, { data: processo }] = await Promise.all([
      client.from('secretaria_contactos').select('nome,email,principal,em_cc,contactavel').eq('company_id', atual.company_id).eq('contactavel', true),
      client.from('secretaria_pendencias').select('id,periodo,tipo,descricao,numero,data_documento,valor_cents,banco').eq('company_id', atual.company_id).eq('estado', 'pendente').eq('acompanhar', true).order('data_documento', { nullsFirst: false }).limit(500),
      client.from('secretaria_processos').select('dia_limite').eq('id', atual.processo_id).maybeSingle(),
    ]);
    const principal = (contactos ?? []).find((c) => c.principal);
    const email = comporEmail({ tipo: atual.tipo, assunto: atual.assunto, corpo: atual.corpo, empresa: atual.empresa?.name ?? '', contacto: principal?.nome, pendencias: (pendencias ?? []) as PendenciaAberta[], diaLimite: processo?.dia_limite });
    previa = {
      assunto: email.assunto, para: principal?.email ?? 'Sem contacto principal', cc: (contactos ?? []).filter((c) => c.em_cc && !c.principal).map((c) => c.email),
      html: html({ chave: 'previa', para: '', assunto: email.assunto, titulo: email.titulo, paragrafos: email.paragrafos, rodape: email.rodape, botao: { texto: 'Entregar os documentos', url: 'https://portal.rr-contabilidade.com/' } }),
    };
  }

  return (
    <div className={s.pagina}>
      <Avisos erro={pedido.erro} mensagem={pedido.mensagem} />
      {lista.length > 0 && <Faixa tom="atencao"><span><strong>{lista.length === 1 ? '1 pedido aguarda' : `${lista.length} pedidos aguardam`} a sua decisão.</strong> Nenhum destes emails será enviado sem a sua aprovação.</span></Faixa>}

      {lista.length === 0 ? (
        <div className={`${s.bloco} ${s.vazioPequeno}`}><strong>Nada por aprovar</strong><span>Quando iniciar um processo, o primeiro email espera aqui pela sua decisão.</span></div>
      ) : (
        <div className={`${s.duas} ${s.lateralPrimeiro}`} style={{ gridTemplateColumns: 'minmax(min(20rem,100%),1fr) minmax(0,1.8fr)' }}>
          <section className="pilha pilha-3" aria-label="Fila de aprovação">
            <h3>Fila de aprovação</h3>
            <div className={s.fila}>
              {lista.map((x) => (
                <Link prefetch={false} key={x.id} href={`/secretaria/aprovar?e=${x.id}`} className={s.filaItem} aria-current={x.id === atual?.id ? 'true' : undefined}>
                  <strong>{x.empresa?.name}</strong>
                  <span>{x.tipo === 'pedido' ? 'Primeiro pedido' : 'Insistência'} · {x.pendencias} documento{x.pendencias === 1 ? '' : 's'} · {dataHoraPt(x.criado_em)}</span>
                </Link>
              ))}
            </div>
          </section>

          {atual && previa && (
            <section className={s.bloco} aria-label="O email que vai sair">
              <div className={s.blocoTitulo}>
                <h3>O email que vai sair</h3>
                <p>Ao aprovar, o email é enviado de imediato.</p>
              </div>
              <dl className={s.emailDados}>
                <dt>Para</dt><dd>{previa.para}</dd>
                {previa.cc.length > 0 && <><dt>Cc</dt><dd>{previa.cc.join(', ')}</dd></>}
                <dt>Assunto</dt><dd>{previa.assunto}</dd>
              </dl>
              <iframe className={s.emailFolha} title="Pré-visualização do email" sandbox="allow-same-origin" srcDoc={previa.html} />
              <details className={s.editar}>
                <summary>Editar este email</summary>
                <form action={decidirEnvio} className="pilha pilha-3">
                  <input type="hidden" name="envio" value={atual.id} /><input type="hidden" name="decisao" value="aprovar" /><input type="hidden" name="voltar" value="/secretaria/aprovar" />
                  <label className="campo"><span>Assunto</span><input name="assunto" className="entrada" maxLength={250} defaultValue={atual.assunto} /></label>
                  <label className="campo"><span>Texto</span><textarea name="corpo" rows={10} maxLength={8000} className="entrada" defaultValue={atual.corpo} /></label>
                  <div className={s.linhaBotoes}><Submeter className="btn btn-sm" aDecorrer="A enviar…">Guardar, aprovar e enviar</Submeter></div>
                </form>
              </details>
              <div className={s.linhaBotoes}>
                <form action={decidirEnvio}>
                  <input type="hidden" name="envio" value={atual.id} /><input type="hidden" name="decisao" value="rejeitar" /><input type="hidden" name="voltar" value="/secretaria/aprovar" />
                  <Submeter className="btn btn-secundario btn-sm" aDecorrer="A rejeitar…">Rejeitar</Submeter>
                </form>
                <form action={decidirEnvio}>
                  <input type="hidden" name="envio" value={atual.id} /><input type="hidden" name="decisao" value="aprovar" /><input type="hidden" name="voltar" value="/secretaria/aprovar" />
                  <Submeter className="btn btn-sm" aDecorrer="A enviar…">Aprovar e enviar</Submeter>
                </form>
              </div>
              {atual.tipo === 'pedido' && <p className="pequeno tenue">Rejeitar o primeiro pedido cancela o processo.</p>}
            </section>
          )}
        </div>
      )}

      {(falhados ?? []).length > 0 && (
        <section className="pilha pilha-3">
          <h3>Emails que falharam</h3>
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Cliente</th><th>Tipo</th><th>Motivo</th><th className={s.direita}>Ação</th></tr></thead>
              <tbody>
                {(falhados as unknown as Envio[]).map((x) => (
                  <tr key={x.id}>
                    <td data-rotulo=""><strong>{x.empresa?.name}</strong></td>
                    <td data-rotulo="Tipo">{x.tipo === 'pedido' ? 'Pedido' : 'Insistência'}</td>
                    <td data-rotulo="Motivo" className={s.detalhe}>{x.erro ?? '—'}</td>
                    <td data-rotulo="" className={s.direita}>
                      <form action={repetirEnvio}><input type="hidden" name="envio" value={x.id} /><input type="hidden" name="voltar" value="/secretaria/aprovar" />
                        <Submeter className={s.acaoPequena} aDecorrer="A enviar…">Tentar novamente</Submeter></form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {(recentes ?? []).length > 0 && (
        <section className="pilha pilha-3">
          <h3>Decididos recentemente</h3>
          <div className={s.envolve}>
            <table className={s.tabela}>
              <thead><tr><th>Cliente</th><th>Tipo</th><th>Estado</th><th>Quando</th></tr></thead>
              <tbody>
                {(recentes as unknown as Envio[]).map((x) => (
                  <tr key={x.id}>
                    <td data-rotulo=""><Link prefetch={false} className={s.nome} href={`/secretaria/clientes/${x.company_id}?aba=historico`}>{x.empresa?.name}</Link></td>
                    <td data-rotulo="Tipo">{x.tipo === 'pedido' ? 'Pedido' : 'Insistência'}</td>
                    <td data-rotulo="Estado"><span className={ESTADOS_ENVIO[x.estado].classe}>{ESTADOS_ENVIO[x.estado].nome}</span></td>
                    <td data-rotulo="Quando" className={s.nowrap}>{dataHoraPt(x.enviado_em ?? x.criado_em)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}
