import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { recoverPayment, releaseUnknownPayment, verifyPayment } from '@/lib/payment-management-actions';
import { ESTADO_PAGAMENTO, dataHora, euros } from '@/lib/apresentar';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Pagamentos' };

export default async function Pagamentos({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const { data: tentativas, error } = await client
    .from('irs_checkouts')
    .select('id,account_id,case_id,state,provider_order_id,amount_cents,created_at,paid_at,client:client_accounts(name)')
    .order('created_at', { ascending: false })
    .limit(100);

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <p className="aviso">
        Últimas 100 tentativas. Um pagamento só fica confirmado depois de uma consulta autenticada à Revolut, ou
        por gratuitidade e desconto integral aplicados no servidor.
      </p>

      <Secao titulo="Tentativas">
        {error ? (
          <p className="aviso aviso-critico">Não foi possível carregar as tentativas.</p>
        ) : !tentativas?.length ? (
          <div className="vazio">
            <strong>Sem tentativas</strong>
            <p>Ainda ninguém iniciou um pagamento nesta campanha.</p>
          </div>
        ) : (
          <div>
            {tentativas.map((tentativa) => {
              const porReconciliar = !tentativa.provider_order_id && ['creating', 'unknown'].includes(tentativa.state);
              return (
                <details className={e.ficha} key={tentativa.id}>
                  <summary className={e.fichaResumo}>
                    <span className={e.fichaNome}>
                      {(tentativa.client as unknown as { name: string } | null)?.name ?? 'Cliente'}
                    </span>
                    <span className={`${e.fichaEmail} numero`}>{euros(tentativa.amount_cents)}</span>
                    <span className={e.fichaEtiquetas}>
                      <span className="etiqueta etiqueta-sem-ponto">{dataHora(tentativa.created_at)}</span>
                      <span className={`etiqueta ${ESTADO_PAGAMENTO[tentativa.state]?.classe ?? ''}`}>
                        {ESTADO_PAGAMENTO[tentativa.state]?.rotulo ?? tentativa.state}
                      </span>
                    </span>
                  </summary>

                  <div className={e.fichaCorpo}>
                    <p className="micro tenue">
                      Referência {tentativa.id}
                      <br />
                      Ordem Revolut: {tentativa.provider_order_id || 'não associada'}
                    </p>

                    <div className={e.fichaCaixas}>
                      {tentativa.provider_order_id && tentativa.state !== 'paid' && (
                        <div className={e.fichaCaixa}>
                          <h3>Confirmar</h3>
                          <form action={verifyPayment}>
                            <input name="checkout" type="hidden" value={tentativa.id} />
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="A consultar…">
                              Confirmar estado na Revolut
                            </Submeter>
                          </form>
                        </div>
                      )}

                      {porReconciliar && (
                        <>
                          <div className={e.fichaCaixa}>
                            <h3>Recuperar ordem</h3>
                            <form action={recoverPayment} className="pilha pilha-3">
                              <input name="checkout" type="hidden" value={tentativa.id} />
                              <label className="campo">
                                <span>ID da ordem na conta Revolut Merchant</span>
                                <input name="order_id" className="entrada" required maxLength={120} />
                              </label>
                              <Submeter className="btn btn-secundario btn-sm" aDecorrer="A verificar…">
                                Verificar e recuperar
                              </Submeter>
                            </form>
                          </div>

                          <div className={`${e.fichaCaixa} ${e.perigo}`}>
                            <h3>Libertar sem cobrança</h3>
                            <p className="pequeno">
                              Use só depois de confirmar na conta Revolut Merchant que não existe ordem pagável nem
                              cobrança para esta referência. Uma verificação errada permite um pagamento duplicado.
                            </p>
                            <form action={releaseUnknownPayment} className="pilha pilha-3">
                              <input name="checkout" type="hidden" value={tentativa.id} />
                              <label className="caixa">
                                <input name="checked" type="checkbox" required />
                                <span className="pequeno">Confirmei que não há ordem pagável nem cobrança.</span>
                              </label>
                              <label className="campo">
                                <span>Escreva SEM PAGAMENTO</span>
                                <input name="confirmation" className="entrada" required autoComplete="off" />
                              </label>
                              <Submeter className="btn btn-critico btn-sm" aDecorrer="A libertar…">
                                Libertar tentativa
                              </Submeter>
                            </form>
                          </div>
                        </>
                      )}
                    </div>
                  </div>
                </details>
              );
            })}
          </div>
        )}
      </Secao>
    </>
  );
}
