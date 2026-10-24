import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { createDiscount, toggleDiscount } from '@/lib/management-actions';
import { data as formatarData } from '@/lib/apresentar';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Descontos' };

const EUROS = new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR' });

export default async function Descontos({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const [{ data: codigos, error }, { data: utilizacoes }] = await Promise.all([
    client.from('discount_codes').select('*').order('created_at', { ascending: false }),
    // Uma tentativa pendente já reserva uma utilização: assim o limite não é ultrapassado.
    client.from('irs_checkouts').select('discount_id,state').in('state', ['creating', 'pending', 'unknown', 'paid']),
  ]);

  const contar = (id: string) => utilizacoes?.filter((uso) => uso.discount_id === id).length ?? 0;

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <Secao titulo="Criar código" nota="As restrições combinam-se: pode limitar a um cliente, a um prazo e a um número de utilizações.">
        <form action={createDiscount} className="cartao pilha pilha-4">
          <div className="grelha grelha-auto">
            <label className="campo">
              <span>Código</span>
              <input name="code" className="entrada" pattern="[A-Za-z0-9_-]{3,40}" maxLength={40} required placeholder="PRIMAVERA26" />
            </label>
            <label className="campo">
              <span>Tipo</span>
              <select name="kind" className="entrada">
                <option value="percentage">Percentagem (%)</option>
                <option value="fixed">Valor fixo (€)</option>
              </select>
            </label>
            <label className="campo">
              <span>Valor</span>
              <input name="value" type="number" className="entrada" min="0.01" step="0.01" required />
            </label>
            <label className="campo">
              <span>Email do cliente</span>
              <input name="email" type="email" className="entrada" maxLength={254} />
              <small>Deixe vazio para o código ficar aberto a qualquer cliente.</small>
            </label>
            <label className="campo">
              <span>Início (UTC)</span>
              <input name="starts_at" type="datetime-local" className="entrada" />
            </label>
            <label className="campo">
              <span>Fim (UTC)</span>
              <input name="ends_at" type="datetime-local" className="entrada" />
            </label>
            <label className="campo">
              <span>Máximo de utilizações</span>
              <input name="max_uses" type="number" className="entrada" min="1" step="1" />
            </label>
          </div>
          <Submeter className="btn" aDecorrer="A criar…">
            Criar código
          </Submeter>
        </form>
      </Secao>

      <Secao titulo="Códigos existentes">
        {error ? (
          <p className="aviso aviso-critico">Não foi possível carregar os códigos.</p>
        ) : !codigos?.length ? (
          <div className="vazio">
            <strong>Sem códigos</strong>
            <p>Crie o primeiro acima. Pode desativá-lo a qualquer momento sem o apagar.</p>
          </div>
        ) : (
          <div className="tabela-envolve">
            <table className="tabela">
              <thead>
                <tr>
                  <th>Código</th>
                  <th>Desconto</th>
                  <th>Utilizações</th>
                  <th>Validade</th>
                  <th>Estado</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {codigos.map((codigo) => (
                  <tr key={codigo.id}>
                    <td>
                      <strong>{codigo.code}</strong>
                      {codigo.allowed_user && <div className="micro tenue">Limitado a um cliente</div>}
                    </td>
                    <td className="numero">
                      {codigo.kind === 'percentage' ? `${codigo.value / 100} %` : EUROS.format(codigo.value / 100)}
                    </td>
                    <td className="numero">
                      {contar(codigo.id)}
                      {codigo.max_uses ? ` / ${codigo.max_uses}` : ''}
                    </td>
                    <td className="pequeno suave">
                      {codigo.starts_at || codigo.ends_at
                        ? `${formatarData(codigo.starts_at)} — ${formatarData(codigo.ends_at)}`
                        : 'Sem prazo'}
                    </td>
                    <td>
                      <span className={`etiqueta ${codigo.active ? 'etiqueta-positivo' : ''}`}>
                        {codigo.active ? 'Ativo' : 'Inativo'}
                      </span>
                    </td>
                    <td>
                      <form action={toggleDiscount}>
                        <input name="discount" type="hidden" value={codigo.id} />
                        <input name="active" type="hidden" value={codigo.active ? 'false' : 'true'} />
                        <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">
                          {codigo.active ? 'Desativar' : 'Ativar'}
                        </Submeter>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Secao>
    </>
  );
}
