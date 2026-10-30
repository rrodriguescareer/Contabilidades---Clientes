import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import Link from 'next/link';
import { createCompany, associateCompany, toggleCompanyAccess } from '@/lib/management-actions';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Empresas' };

type Ligacao = { user_id: string; active: boolean; profile: { email: string } | null };
type Estado = { id: string; data_corte: string | null; tem_cegid: boolean; documentos: number; por_ver: number; atrasados: number; completo: boolean | null; mensagens: number; pessoal: number; impostos_atrasados: number };
type Portal = { mes_em_curso: string; prazo: string; empresas: Estado[] };

const data = (iso: string | null) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : null);

export default async function Empresas({ searchParams }: { searchParams: Promise<{ erro?: string; mensagem?: string }> }) {
  const { client } = await session();
  const parametros = await searchParams;

  const [{ data: empresas, error }, { data: bruto }] = await Promise.all([
    client
      .from('companies')
      .select('id,name,nif,active,company_users(user_id,active,profile:profiles(email))')
      .order('created_at', { ascending: false })
      .limit(100),
    client.rpc('gestao_empresas'),
  ]);
  const portal = bruto as Portal | null;
  const estado = (id: string) => portal?.empresas.find((x) => x.id === id);

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <p className="aviso">
        Cada empresa entra no portal Empresas com a sua data de corte e a sua ligação ao Cegid. Para um cliente o ver,
        precisa do acesso Empresas (em Utilizadores) e de estar associado aqui. Os documentos de cada mês chegam até ao dia 10.
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
                      {(() => {
                        const x = estado(empresa.id);
                        if (!x) return null;
                        return (
                          <>
                            <span className={`etiqueta ${x.data_corte ? 'etiqueta-positivo' : 'etiqueta-atencao'}`}>
                              {x.data_corte ? `Corte ${data(x.data_corte)}` : 'Sem data de corte'}
                            </span>
                            {!x.tem_cegid && <span className="etiqueta etiqueta-atencao">Sem Cegid</span>}
                            {x.por_ver > 0 && <span className="etiqueta etiqueta-acao">{x.por_ver} por ver</span>}
                            {x.atrasados > 0 && <span className="etiqueta etiqueta-critico">{x.atrasados} fora do prazo</span>}
                            {x.mensagens > 0 && <span className="etiqueta etiqueta-acao">{x.mensagens} {x.mensagens === 1 ? 'mensagem' : 'mensagens'}</span>}
                            {x.pessoal > 0 && <span className="etiqueta etiqueta-acao">{x.pessoal} de pessoal</span>}
                            {x.impostos_atrasados > 0 && <span className="etiqueta etiqueta-critico">{x.impostos_atrasados} imposto(s) em atraso</span>}
                          </>
                        );
                      })()}
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
                        <h3>Portal Empresas</h3>
                        {(() => {
                          const x = estado(empresa.id);
                          return (
                            <p className="pequeno">
                              {x?.data_corte ? `Contabilidade fechada até ${data(x.data_corte)}.` : 'Sem data de corte: o cliente ainda não tira saldos nem balancetes.'}
                              <br />
                              {x?.tem_cegid ? 'Ligada ao Cegid.' : 'Ainda sem credenciais do Cegid.'}
                              {portal && x ? ` ${x.documentos} documentos do mês em curso${x.completo ? ', dado como completo' : ''}.` : ''}
                            </p>
                          );
                        })()}
                        <Link className="btn btn-sm" href={`/empresas/${empresa.id}`}>
                          Abrir a empresa: definições, ficha, documentos, impostos, pessoal
                        </Link>
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
