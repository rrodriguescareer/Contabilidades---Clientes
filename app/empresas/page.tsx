import {session} from '@/lib/auth';
import ManagementShell from '@/components/management-shell';
import {Submit} from '@/components/forms';
import {createCompany,associateCompany,toggleCompanyAccess} from '@/lib/management-actions';
export const dynamic='force-dynamic';
export default async function Companies({searchParams}:{searchParams:Promise<{erro?:string;mensagem?:string}>}){
 const {client}=await session(),params=await searchParams;
 const [{data:companies,error},{data:links,error:linksError}]=await Promise.all([
 client.from('companies').select('id,name,nif,active').order('created_at',{ascending:false}),
 client.from('company_users').select('company_id,user_id,active'),
 ]);
 const ids=[...new Set(links?.map(l=>l.user_id)||[])];const {data:users}=ids.length?await client.from('profiles').select('id,email,full_name').in('id',ids):{data:[]};
 return <ManagementShell title="Empresas e associações" error={params.erro} message={params.mensagem}><section className="panel"><h2>Criar empresa</h2><form action={createCompany}><div className="field-grid"><label>Nome da empresa<input name="name" maxLength={200} required/></label><label>NIF da empresa<input name="nif" pattern="[1-9][0-9]{8}" maxLength={9} required/></label></div><label>Email do cliente associado<input name="email" type="email" maxLength={254} required/></label><Submit>Criar e associar</Submit></form></section>
 <section className="panel"><h2>Empresas registadas</h2>{error||linksError?<p>Não foi possível carregar as empresas.</p>:companies?.length===0?<p>Ainda sem empresas.</p>:companies?.map(c=><details key={c.id}><summary>{c.name} · {c.nif}</summary>{links?.filter(l=>l.company_id===c.id).map(l=><form className="access-row" key={l.user_id} action={toggleCompanyAccess}><input name="company" type="hidden" value={c.id}/><input name="user" type="hidden" value={l.user_id}/><input name="active" type="hidden" value={l.active?'false':'true'}/><p>{users?.find(u=>u.id===l.user_id)?.email||'Utilizador'} · {l.active?'Ativo':'Bloqueado'}</p><Submit>{l.active?'Desativar acesso':'Ativar acesso'}</Submit></form>)}<form action={associateCompany}><input name="company" type="hidden" value={c.id}/><label>Associar outro utilizador registado<input name="email" type="email" required maxLength={254}/></label><Submit>Associar utilizador</Submit></form></details>)}</section><p className="fine">As empresas e os respetivos acessos ficam preparados para a plataforma Empresas. O módulo operacional dessa plataforma será desenvolvido posteriormente.</p></ManagementShell>;
}
