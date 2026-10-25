import Link from 'next/link';
import { ownerSession as session } from '@/lib/auth';
import { Avisos, Secao } from '@/components/consola';
import { Submeter } from '@/components/forms';
import { blockUser, deleteUser, setBilling, setAccountant, inviteManagedUser, setModuleAccess } from '@/lib/management-actions';
import { adminConfigured } from '@/lib/admin-client';
import { data as formatarData } from '@/lib/apresentar';
import e from '@/components/consola.module.css';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'Utilizadores' };

const POR_PAGINA = 50;

export default async function Utilizadores({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; pagina?: string; erro?: string; mensagem?: string }>;
}) {
  const { client, user } = await session();
  const parametros = await searchParams;

  const pagina = Math.max(0, Math.min(100000, Number.parseInt(parametros.pagina || '0', 10) || 0));
  const procura = (parametros.q || '').trim().slice(0, 200);
  // O ilike trata % e _ como curingas: escapá-los evita pesquisas acidentais amplas.
  const literal = procura.replace(/[\\%_]/g, '\\$&');

  let consulta = client
    .from('profiles')
    .select(
      'id,email,full_name,nif,birth_date,phone,street,postal_code,locality,disabled_at,deleted_at,onboarding_completed_at,irs_free,forced_discount_id',
      { count: 'exact' },
    )
    .order('created_at', { ascending: false })
    .range(pagina * POR_PAGINA, pagina * POR_PAGINA + POR_PAGINA - 1);
  if (procura) consulta = consulta.ilike(procura.includes('@') ? 'email' : 'full_name', `%${literal}%`);

  const [{ data: utilizadores, count, error }, { data: descontos }, { data: equipa }, { data: acessos }] = await Promise.all([
    consulta,
    client.from('discount_codes').select('id,code,active').order('code'),
    client.from('staff_users').select('user_id,active,managed_by'),
    client.from('account_access').select('user_id,account_id,irs,business,active').eq('role', 'owner'),
  ]);

  const ids = utilizadores?.map((perfil) => perfil.id) ?? [];
  const { data: convites } = ids.length
    ? await client.from('household_invitations').select('id,email,accepted_by,accepted_at').in('accepted_by', ids)
    : { data: [] };

  const eContabilista = (id: string) =>
    Boolean(equipa?.some((membro) => membro.user_id === id && membro.active && membro.managed_by));

  const acessoDe = (id: string) => acessos?.find((a) => a.user_id === id);

  const total = count ?? 0;
  const ligacao = (destino: number) => `/utilizadores?pagina=${destino}&q=${encodeURIComponent(procura)}`;

  return (
    <>
      <Avisos erro={parametros.erro} mensagem={parametros.mensagem} />

      <Secao titulo="Criar acesso por convite" nota="O convite cria a conta; as empresas associam-se depois.">
        <form action={inviteManagedUser} className="cartao pilha pilha-4">
          <div className="grelha grelha-auto">
            <label className="campo">
              <span>Email</span>
              <input name="email" type="email" className="entrada" required maxLength={254} />
            </label>
            <label className="campo">
              <span>Perfil</span>
              <select name="role" className="entrada">
                <option value="client">Cliente</option>
                <option value="accountant">Contabilista certificado</option>
              </select>
            </label>
          </div>
          <Submeter className="btn" aDecorrer="A enviar…">
            Enviar convite de acesso
          </Submeter>
        </form>
      </Secao>

      <Secao titulo="Registados" nota={`${total} ${total === 1 ? 'utilizador' : 'utilizadores'} · página ${pagina + 1}`}>
        <form method="get" className="linha" style={{ alignItems: 'flex-end' }}>
          <label className="campo cresce" style={{ maxWidth: '26rem' }}>
            <span>Pesquisar por nome ou email</span>
            <input name="q" className="entrada" defaultValue={procura} maxLength={200} />
          </label>
          <button className="btn btn-secundario">Pesquisar</button>
        </form>

        {error ? (
          <p className="aviso aviso-critico">Não foi possível carregar os utilizadores.</p>
        ) : !utilizadores?.length ? (
          <div className="vazio">
            <strong>Nada encontrado</strong>
            <p>{procura ? 'Nenhum utilizador corresponde a esta pesquisa.' : 'Ainda não há utilizadores registados.'}</p>
          </div>
        ) : (
          <div>
            {utilizadores.map((perfil) => {
              const contabilista = eContabilista(perfil.id);
              const estado = perfil.deleted_at
                ? { rotulo: 'Eliminado', classe: 'etiqueta-critico' }
                : perfil.disabled_at
                  ? { rotulo: 'Bloqueado', classe: 'etiqueta-critico' }
                  : perfil.onboarding_completed_at
                    ? { rotulo: 'Dados completos', classe: 'etiqueta-positivo' }
                    : { rotulo: 'Registo por completar', classe: 'etiqueta-atencao' };

              return (
                <details className={e.ficha} key={perfil.id}>
                  <summary className={e.fichaResumo}>
                    <span className={e.fichaNome}>{perfil.full_name}</span>
                    <span className={e.fichaEmail}>{perfil.email || 'Conta eliminada'}</span>
                    <span className={e.fichaEtiquetas}>
                      {contabilista && <span className="etiqueta etiqueta-acao">Contabilista</span>}
                      {acessoDe(perfil.id)?.irs && <span className="etiqueta">IRS</span>}
                      {acessoDe(perfil.id)?.business && <span className="etiqueta">Empresas</span>}
                      {perfil.irs_free && <span className="etiqueta">IRS gratuito</span>}
                      <span className={`etiqueta ${estado.classe}`}>{estado.rotulo}</span>
                    </span>
                  </summary>

                  <div className={e.fichaCorpo}>
                    <p className="pequeno suave">
                      NIF {perfil.nif || 'por preencher'} · {perfil.phone || 'sem telemóvel'} ·{' '}
                      {perfil.birth_date ? formatarData(perfil.birth_date) : 'sem data de nascimento'}
                      <br />
                      {[perfil.street, perfil.postal_code, perfil.locality].filter(Boolean).join(', ') || 'Sem morada'}
                    </p>

                    {convites
                      ?.filter((convite) => convite.accepted_by === perfil.id)
                      .map((convite) => (
                        <p className="micro tenue" key={convite.id}>
                          Convite aceite com {convite.email} em {formatarData(convite.accepted_at)}
                        </p>
                      ))}

                    {perfil.id !== user.id && !perfil.deleted_at && (
                      <div className={e.fichaCaixas}>
                        <div className={e.fichaCaixa}>
                          <h3>Perfil e acesso</h3>
                          <form action={setAccountant} className="pilha pilha-2">
                            <input name="user" type="hidden" value={perfil.id} />
                            <input name="enabled" type="hidden" value={contabilista ? 'false' : 'true'} />
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">
                              {contabilista ? 'Remover acesso de contabilista' : 'Dar acesso de contabilista'}
                            </Submeter>
                          </form>
                          <form action={blockUser}>
                            <input name="user" type="hidden" value={perfil.id} />
                            <input name="blocked" type="hidden" value={perfil.disabled_at ? 'false' : 'true'} />
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="…">
                              {perfil.disabled_at ? 'Remover bloqueio' : 'Bloquear utilizador'}
                            </Submeter>
                          </form>
                        </div>

                        <div className={e.fichaCaixa}>
                          <h3>Plataformas</h3>
                          <p className="pequeno suave">
                            O cliente de IRS cria-se a si próprio. O de empresas é criado por si. Quem quiser a
                            outra plataforma, recebe o acesso aqui.
                          </p>
                          <form action={setModuleAccess} className="pilha pilha-3">
                            <input name="user" type="hidden" value={perfil.id} />
                            <label className="caixa">
                              <input name="irs" type="checkbox" defaultChecked={acessoDe(perfil.id)?.irs ?? false} />
                              <span className="pequeno">IRS 2026</span>
                            </label>
                            <label className="caixa">
                              <input name="empresas" type="checkbox" defaultChecked={acessoDe(perfil.id)?.business ?? false} />
                              <span className="pequeno">
                                Clientes Empresa
                                <br />
                                <span className="tenue">As empresas associam-se no módulo Empresas.</span>
                              </span>
                            </label>
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="A guardar…">
                              Guardar acessos
                            </Submeter>
                          </form>
                        </div>

                        <div className={e.fichaCaixa}>
                          <h3>Condições de preço</h3>
                          <form action={setBilling} className="pilha pilha-3">
                            <input name="user" type="hidden" value={perfil.id} />
                            <label className="caixa">
                              <input name="free" type="checkbox" defaultChecked={perfil.irs_free} />
                              <span className="pequeno">Cliente gratuito — IRS sem cobrança.</span>
                            </label>
                            <label className="campo">
                              <span>Código obrigatório</span>
                              <select name="discount" className="entrada" defaultValue={perfil.forced_discount_id || ''}>
                                <option value="">Sem desconto obrigatório</option>
                                {descontos?.map((desconto) => (
                                  <option key={desconto.id} value={desconto.id}>
                                    {desconto.code}
                                    {desconto.active ? '' : ' (inativo)'}
                                  </option>
                                ))}
                              </select>
                            </label>
                            <Submeter className="btn btn-secundario btn-sm" aDecorrer="A guardar…">
                              Guardar condições
                            </Submeter>
                          </form>
                        </div>

                        <div className={`${e.fichaCaixa} ${e.perigo}`}>
                          <h3>Eliminar utilizador</h3>
                          <p className="pequeno">
                            A autenticação é eliminada e o acesso bloqueado. Os documentos fiscais e financeiros
                            sujeitos a conservação legal são preservados.
                          </p>
                          <form action={deleteUser} className="pilha pilha-3">
                            <input name="user" type="hidden" value={perfil.id} />
                            <label className="campo">
                              <span>Escreva o email para confirmar</span>
                              <input name="confirmation" type="email" className="entrada" autoComplete="off" required />
                            </label>
                            <button className="btn btn-critico btn-sm" disabled={!adminConfigured()}>
                              Eliminar utilizador
                            </button>
                            {!adminConfigured() && (
                              <p className="micro">
                                A eliminação precisa da configuração administrativa indicada em Configurações.
                              </p>
                            )}
                          </form>
                        </div>
                      </div>
                    )}
                  </div>
                </details>
              );
            })}
          </div>
        )}

        {(pagina > 0 || (pagina + 1) * POR_PAGINA < total) && (
          <div className="linha">
            {pagina > 0 && (
              <Link className="btn btn-secundario btn-sm" href={ligacao(pagina - 1)}>
                ← Anterior
              </Link>
            )}
            {(pagina + 1) * POR_PAGINA < total && (
              <Link className="btn btn-secundario btn-sm" href={ligacao(pagina + 1)}>
                Seguinte →
              </Link>
            )}
          </div>
        )}
      </Secao>
    </>
  );
}
