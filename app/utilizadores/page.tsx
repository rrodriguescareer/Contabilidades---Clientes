import {session} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
import {Submit} from '@/components/forms';
import {blockUser,deleteUser,setBilling} from '@/lib/management-actions';
import {adminConfigured} from '@/lib/admin-client';
import Link from 'next/link';
export const dynamic='force-dynamic';
export default async function Users({searchParams}:{searchParams:Promise<{q?:string;pagina?:string;erro?:string;mensagem?:string}>}){
 const {client,user}=await session();const params=await searchParams,page=Math.max(0,Math.min(100000,Number.parseInt(params.pagina||'0',10)||0));
 const search=(params.q||'').trim().slice(0,200),literal=search.replace(/[\\%_]/g,'\\$&');
 let query=client.from('profiles').select('id,email,full_name,nif,birth_date,phone,street,postal_code,locality,disabled_at,deleted_at,onboarding_completed_at,irs_free,forced_discount_id',{count:'exact'}).order('created_at',{ascending:false}).range(page*50,page*50+49);
 if(search)query=query.ilike(search.includes('@')?'email':'full_name',`%${literal}%`);
 const {data:users,count,error}=await query;
 const {data:discounts}=await client.from('discount_codes').select('id,code,active').order('code');
 const ids=users?.map(u=>u.id)||[];
 const {data:invitations,error:invitationError}=ids.length?await client.from('household_invitations').select('id,email,accepted_by,accepted_at').in('accepted_by',ids):{data:[],error:null};
 return <ManagementShell title="Utilizadores" error={params.erro} message={params.mensagem}><section className="panel"><form method="get"><label>Pesquisar por nome ou email<input name="q" defaultValue={search} maxLength={200}/></label><button>Pesquisar</button></form><p>{count??0} utilizadores · página {page+1}</p>
 {error||invitationError?<div className="alert error">Não foi possível carregar os utilizadores ou os convites.</div>:users?.map(p=><details key={p.id}><summary>{p.full_name} · {p.email||'Conta eliminada'} · {p.deleted_at?'Eliminado':p.disabled_at?'Bloqueado':p.onboarding_completed_at?'Dados completos':'Registo por completar'}</summary><p className="fine">NIF: {p.nif||'Por preencher'} · {p.phone||'Sem telemóvel'}<br/>{[p.street,p.postal_code,p.locality].filter(Boolean).join(' · ')}</p>{invitations?.filter(i=>i.accepted_by===p.id).map(i=><p key={i.id} className="fine">Convite aceite com {i.email} em {new Date(i.accepted_at).toLocaleDateString('pt-PT')}</p>)}
 {p.id!==user.id&&!p.deleted_at&&<><form action={blockUser}><input name="user" type="hidden" value={p.id}/><input name="blocked" type="hidden" value={p.disabled_at?'false':'true'}/><Submit>{p.disabled_at?'Remover bloqueio':'Bloquear utilizador'}</Submit></form><form action={setBilling}><input name="user" type="hidden" value={p.id}/><label className="check"><input name="free" type="checkbox" defaultChecked={p.irs_free}/>Cliente gratuito — IRS sem cobrança</label><label>Código obrigatório<select name="discount" defaultValue={p.forced_discount_id||''}><option value="">Sem desconto obrigatório</option>{discounts?.map(d=><option key={d.id} value={d.id}>{d.code}{d.active?'':' (inativo)'}</option>)}</select></label><Submit>Guardar condições de preço</Submit></form><details><summary className="danger">Eliminar utilizador</summary><p>A autenticação será eliminada e o acesso bloqueado. Documentos fiscais e financeiros sujeitos a conservação serão preservados.</p><form action={deleteUser}><input name="user" type="hidden" value={p.id}/><label>Escreva o email para confirmar<input name="confirmation" type="email" autoComplete="off" required/></label><button className="danger" disabled={!adminConfigured()}>Eliminar utilizador</button>{!adminConfigured()&&<p className="fine">A eliminação da autenticação necessita da configuração administrativa indicada em Configuração.</p>}</form></details></>}
 </details>)}</section><div className="module-links">{page>0&&<Link className="button" href={`/utilizadores?pagina=${page-1}&q=${encodeURIComponent(search)}`}>← Anterior</Link>}{(page+1)*50<(count||0)&&<Link className="button" href={`/utilizadores?pagina=${page+1}&q=${encodeURIComponent(search)}`}>Seguinte →</Link>}</div></ManagementShell>;
}
