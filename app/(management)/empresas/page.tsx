import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { saveCompanyIntegration } from '@/lib/integration-actions';
import { createCompany, associateCompany, toggleCompanyAccess } from '@/lib/management-actions';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Empresas' };

type Ligacao = { user_id: string; active: boolean; profile: { email: string } | null };

export default async function Empresas({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const { data: empresas, error } = await client
    .from('companies')
    .select('id,name,nif,active,company_users(user_id,active,profile:profiles(email))')
    .order('created_at', { ascending: false })
    .limit(100);

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <p className="aviso">
        As empresas e os respetivos acessos ficam preparados para a plataforma Empresas. O módulo operacional
        dessa plataforma é desenvolvido depois do IRS.
      </p>

      <Secao titulo="Criar empresa" nota="A empresa fica logo associada ao cliente que indicar.">
        <form action={createCompany} className="cartao pilha pilha-4">
          <div className="grelha grelha-auto">
            <label className="campo">
              <span>Nome da empresa</span>
              <input name="name" className="entrada" maxLength={200} required />
            </label>
            <label className="campo">
              <span>NIF da empresa</span>
              <input name="nif" className="entrada" pattern="[1-9][0-9]{8}" maxLength={9} required inputMode="numeric" />
            </label>
            <label className="campo">
              <span>Email do cliente associado</span>
              <input name="email" type="email" className="entrada" maxLength={254} required />
            </label>
          </div>
          <Submeter className="btn" aDecorrer="A criar…">
            Criar e associar
          </Submeter>
        </form>
      </Secao>

      <Secao titulo="Empresas registadas">
        {error ? (
          <p className="aviso aviso-critico">Não foi possível carregar as empresas.</p>
        ) : !empresas?.length ? (
          <div className="vazio">
            <strong>Ainda sem empresas</strong>
            <p>Crie a primeira acima para começar a preparar a plataforma Empresas.</p>
          </div>
        ) : (
          <div>
            {empresas.map((empresa) => {
              const ligacoes = (empresa.company_users ?? []) as unknown as Ligacao[];
              return (
                <details className={e.ficha} key={empresa.id}>
                  <summary className={e.fichaResumo}>
                    <span className={e.fichaNome}>{empresa.name}</span>
                    <span className={e.fichaEmail}>NIF {empresa.nif}</span>
                    <span className={e.fichaEtiquetas}>
                      <span className="etiqueta">{ligacoes.length} {ligacoes.length === 1 ? 'acesso' : 'acessos'}</span>
                      <span className={`etiqueta ${empresa.active ? 'etiqueta-positivo' : 'etiqueta-critico'}`}>
                        {empresa.active ? 'Ativa' : 'Inativa'}
                      </span>
                    </span>
                  </summary>

                  <div className={e.fichaCorpo}>
                    <div className={e.fichaCaixas}>
                      <div className={e.fichaCaixa}>
                        <h3>Acessos</h3>
                        {ligacoes.length === 0 && <p className="pequeno suave">Sem utilizadores associados.</p>}
                        {ligacoes.map((ligacao) => (
                          <form className="linha-entre" key={ligacao.user_id} action={toggleCompanyAccess}>
                            <input name="company" type="hidden" value={empresa.id} />
                            <input name="user" type="hidden" value={ligacao.user_id} />
                            <input name="active" type="hidden" value={ligacao.active ? 'false' : 'true'} />
                            <span className="pequeno">
                              {ligacao.profile?.email || 'Utilizador'}
                              <br />
                              <span className="tenue">{ligacao.active ? 'Ativo' : 'Bloqueado'}</span>
                            </span>
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">
                              {ligacao.active ? 'Desativar' : 'Ativar'}
                            </Submeter>
                          </form>
                        ))}
                        <form action={associateCompany} className="pilha pilha-3">
                          <input name="company" type="hidden" value={empresa.id} />
                          <label className="campo">
                            <span>Associar outro utilizador</span>
                            <input name="email" type="email" className="entrada" required maxLength={254} />
                          </label>
                          <Submeter className="btn btn-secundario btn-sm" aDecorrer="A associar…">
                            Associar
                          </Submeter>
                        </form>
                      </div>

                      <div className={e.fichaCaixa}>
                        <h3>Cegid Business</h3>
                        <form action={saveCompanyIntegration} className="pilha pilha-3">
                          <input name="company" type="hidden" value={empresa.id} />
                          <label className="campo">
                            <span>Credencial API desta empresa</span>
                            <input
                              name="credential"
                              type="password"
                              className="entrada"
                              autoComplete="new-password"
                              required
                              maxLength={16384}
                            />
                            <small>
                              Cada empresa tem a sua credencial, guardada cifrada. Este campo nunca mostra a chave
                              já gravada.
                            </small>
                          </label>
                          <Submeter className="btn btn-secundario btn-sm" aDecorrer="A guardar…">
                            Guardar credencial
                          </Submeter>
                        </form>
                      </div>
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
