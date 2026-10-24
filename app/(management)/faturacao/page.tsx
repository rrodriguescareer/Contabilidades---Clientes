import { ownerSession } from '@/lib/auth';
import { Secao } from '@/components/consola';
import { data as formatarData } from '@/lib/apresentar';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Faturação' };

const EUROS = new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' });

export default async function Faturacao() {
  const { client } = await ownerSession();

  const { data: faturas, error } = await client
    .from('invoices')
    .select('id,reference,issued_at,total,currency,account_id,client:client_accounts(name),payments(amount)')
    .order('issued_at', { ascending: false })
    .limit(100);

  return (
    <>
      <p className="aviso">
        Faturas associadas às contas de IRS. A emissão automática no Cegid e a faturação da plataforma Empresas
        ligam-se quando essas integrações estiverem disponíveis.
      </p>

      <Secao titulo="Últimas faturas">
        {error ? (
          <p className="aviso aviso-critico">Não foi possível carregar as faturas.</p>
        ) : !faturas?.length ? (
          <div className="vazio">
            <strong>Sem faturas</strong>
            <p>Ainda não foram registadas faturas nesta campanha.</p>
          </div>
        ) : (
          <div className="tabela-envolve">
            <table className="tabela">
              <thead>
                <tr>
                  <th>Referência</th>
                  <th>Cliente</th>
                  <th>Emitida</th>
                  <th>Total</th>
                  <th>Recebido</th>
                  <th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {faturas.map((fatura) => {
                  const recebido = ((fatura.payments ?? []) as { amount: number | string }[]).reduce(
                    (soma, pagamento) => soma + Number(pagamento.amount),
                    0,
                  );
                  const liquidada = recebido >= Number(fatura.total);
                  return (
                    <tr key={fatura.id}>
                      <td>
                        <strong>{fatura.reference}</strong>
                      </td>
                      <td>{(fatura.client as unknown as { name: string } | null)?.name ?? '—'}</td>
                      <td className="pequeno suave">{formatarData(fatura.issued_at)}</td>
                      <td className="numero">{EUROS.format(Number(fatura.total))}</td>
                      <td className="numero">{EUROS.format(recebido)}</td>
                      <td>
                        <span className={`etiqueta ${liquidada ? 'etiqueta-positivo' : 'etiqueta-atencao'}`}>
                          {liquidada ? 'Paga' : 'Por liquidar'}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Secao>
    </>
  );
}
