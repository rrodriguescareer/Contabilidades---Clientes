'use server';
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {ownerSession as session} from './auth';
import {adminClient,adminConfigured} from './admin-client';
import {uuid} from './data';
import {validEmail} from './validation';
const text=(f:FormData,k:string)=>String(f.get(k)||'').trim();
function finish(path:string,message:string,error=false):never{revalidatePath('/app');revalidatePath(path);redirect(`${path}?${error?'erro':'mensagem'}=${encodeURIComponent(message)}`);}
export async function blockUser(form:FormData){
 const {client}=await session();const target=text(form,'user');if(!uuid(target))finish('/utilizadores','Utilizador inválido.',true);
 const blocked=form.get('blocked')==='true';const {error}=await client.rpc('set_user_blocked',{target,blocked});
 if(error)finish('/utilizadores','Não foi possível alterar o acesso. A conta do contabilista não pode ser bloqueada.',true);
 finish('/utilizadores',blocked?'Acesso bloqueado.':'Bloqueio removido. Os acessos aos módulos devem ser reativados separadamente.');
}
export async function deleteUser(form:FormData){
 const {client,user}=await session();const target=text(form,'user'),confirmation=text(form,'confirmation').toLowerCase();
 if(!uuid(target)||target===user.id||!adminConfigured())finish('/utilizadores','A eliminação não está disponível para esta conta.',true);
 const {data:profile}=await client.from('profiles').select('email').eq('id',target).single();
 if(!profile?.email||profile.email.toLowerCase()!==confirmation)finish('/utilizadores','Escreva o email do utilizador para confirmar a eliminação.',true);
 const {error:blocked}=await client.rpc('prepare_user_deletion',{target});if(blocked)finish('/utilizadores','Não foi possível bloquear antes da eliminação.',true);
 const {error}=await adminClient().auth.admin.deleteUser(target,true);
 if(error)finish('/utilizadores','O acesso ficou bloqueado, mas a eliminação da autenticação falhou. Pode tentar novamente.',true);
 const {error:finished}=await client.rpc('finish_user_deletion',{target});if(finished)finish('/utilizadores','Autenticação eliminada. Falta concluir o registo de eliminação; contacte o suporte técnico.',true);
 finish('/utilizadores','Utilizador eliminado da autenticação. Elementos fiscais e financeiros sujeitos a conservação foram preservados.');
}
export async function setBilling(form:FormData){
 const {client}=await session();const target=text(form,'user'),discount=text(form,'discount');
 if(!uuid(target)||(discount&&!uuid(discount)))finish('/utilizadores','Utilizador ou desconto inválido.',true);
 const {error}=await client.rpc('set_client_billing',{target,free_service:form.has('free'),required_discount:discount||null});
 if(error)finish('/utilizadores','Não foi possível guardar as condições do cliente.',true);
 finish('/utilizadores','Condições de preço guardadas. Aplicam-se ao próximo checkout; pagamentos já iniciados mantêm o orçamento.');
}
async function findUser(client:Awaited<ReturnType<typeof session>>['client'],email:string){
 if(!validEmail(email))return null;
 const {data}=await client.from('profiles').select('id').eq('email',email.toLowerCase()).is('deleted_at',null).single();return data?.id||null;
}
export async function createCompany(form:FormData){
 const {client}=await session();const name=text(form,'name'),nif=text(form,'nif'),user=await findUser(client,text(form,'email'));
 if(!name||name.length>200||!user||!/^[1-9][0-9]{8}$/.test(nif))finish('/empresas','Confirme o nome, NIF e email de um utilizador registado.',true);
 const {error}=await client.rpc('create_company',{company_name:name,tax_id:nif,client_user:user});
 if(error)finish('/empresas','Não foi possível criar a empresa. O NIF pode já existir.',true);finish('/empresas','Empresa criada e associada ao utilizador.');
}
export async function associateCompany(form:FormData){
 const {client}=await session();const company=text(form,'company'),user=await findUser(client,text(form,'email'));
 if(!uuid(company)||!user)finish('/empresas','Empresa ou utilizador inválido.',true);
 const {error}=await client.from('company_users').upsert({company_id:company,user_id:user,active:true});
 if(error)finish('/empresas','Não foi possível associar.',true);finish('/empresas','Utilizador associado à empresa.');
}
export async function toggleCompanyAccess(form:FormData){
 const {client}=await session();const company=text(form,'company'),user=text(form,'user');if(!uuid(company)||!uuid(user))finish('/empresas','Associação inválida.',true);
 const {error}=await client.from('company_users').update({active:form.get('active')==='true'}).eq('company_id',company).eq('user_id',user);
 if(error)finish('/empresas','Não foi possível alterar.',true);finish('/empresas','Acesso à empresa atualizado.');
}
export async function createDiscount(form:FormData){
 const {client}=await session();const code=text(form,'code').toUpperCase(),kind=text(form,'kind'),amount=Number(text(form,'value').replace(',','.')),limit=text(form,'max_uses'),email=text(form,'email');
 const value=Math.round(amount*(kind==='percentage'?100:100)),user=email?await findUser(client,email):null;
 const start=text(form,'starts_at'),end=text(form,'ends_at');
 // UTC is explicit in the management form; no dependence on the Vercel server timezone.
 const validDate=(v:string)=>!v||/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v)&&Number.isFinite(Date.parse(v+'Z'));
 if(!/^[A-Z0-9_-]{3,40}$/.test(code)||!['fixed','percentage'].includes(kind)||!Number.isSafeInteger(value)||value<=0||(kind==='percentage'&&value>10000)||(limit&&(!/^\d+$/.test(limit)||Number(limit)<1))||(email&&!user)||!validDate(start)||!validDate(end)||(start&&end&&end<=start))finish('/descontos','Verifique o código, valor, cliente, datas e limite de utilizações.',true);
 const {error}=await client.from('discount_codes').insert({code,kind,value,allowed_user:user,starts_at:start?start+':00Z':null,ends_at:end?end+':00Z':null,max_uses:limit?Number(limit):null});
 if(error)finish('/descontos','Não foi possível criar. O código pode já existir.',true);finish('/descontos','Código criado. Todas as restrições preenchidas serão aplicadas em conjunto.');
}
export async function toggleDiscount(form:FormData){
 const {client}=await session();const id=text(form,'discount');if(!uuid(id))finish('/descontos','Código inválido.',true);
 const {error}=await client.from('discount_codes').update({active:form.get('active')==='true'}).eq('id',id);if(error)finish('/descontos','Não foi possível alterar.',true);finish('/descontos','Código atualizado.');
}

export async function setAccountant(form:FormData){
 const {client}=await session();const target=text(form,'user');if(!uuid(target))finish('/utilizadores','Utilizador inválido.',true);
 const {error}=await client.rpc('set_staff_access',{target,enabled:form.get('enabled')==='true'});if(error)finish('/utilizadores','Não foi possível alterar o perfil de contabilista.',true);
 finish('/utilizadores','Perfil atualizado. O acesso profissional exige email confirmado.');
}
export async function inviteManagedUser(form:FormData){
 const {client}=await session();const email=text(form,'email').toLowerCase(),role=text(form,'role');
 if(!validEmail(email)||!['client','accountant'].includes(role)||!adminConfigured()||process.env.AUTH_EMAIL_BRANDING_READY!=='true')finish('/utilizadores','Confirme o email e as configurações de administração e envio de email.',true);
 const {siteUrl}=await import('./supabase');let origin=role==='accountant'?siteUrl():(process.env.NEXT_PUBLIC_EMPRESAS_URL||process.env.NEXT_PUBLIC_IRS_URL||'');
 try{const url=new URL(origin||'');if(url.protocol!=='https:')throw new Error();origin=url.origin;}catch{finish('/utilizadores','Configure o endereço público da gestão para contabilistas e do IRS ou Empresas para clientes.',true);}
 const {data,error}=await adminClient().auth.admin.inviteUserByEmail(email,{redirectTo:`${origin}/auth/callback?next=/nova-password`});
 if(error||!data.user)finish('/utilizadores','Não foi possível criar o convite. Confirme se o email já está registado.',true);
 if(role==='accountant'){const {error:grant}=await client.rpc('set_staff_access',{target:data.user.id,enabled:true});if(grant)finish('/utilizadores','Convite criado; não foi possível atribuir o perfil. Atribua-o na lista de utilizadores.',true);}
 finish('/utilizadores','Convite enviado. Pode associar o cliente às empresas pretendidas.');
}

export async function setModuleAccess(form:FormData){
 const {client}=await session();const target=text(form,'user');
 if(!uuid(target))finish('/utilizadores','Utilizador inválido.',true);
 const {error}=await client.rpc('definir_acessos',{target,com_irs:form.has('irs'),com_empresas:form.has('empresas')});
 if(error)finish('/utilizadores','Não foi possível alterar os acessos.',true);
 finish('/utilizadores','Acessos atualizados. As empresas associam-se no módulo Empresas.');
}
