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
/* Eliminar um utilizador por completo: a conta de que é titular e tudo o que
   está pendurado nela (processos, agregado, rendimentos, documentos e os
   ficheiros, mensagens, pagamentos, registos), confirmado ou não. A ficha no
   Cegid fica: vive lá e é lá que se gere. A ordem importa — primeiro a base
   (numa transação: ou sai tudo ou nada), depois os ficheiros, por fim a
   autenticação. */
export async function deleteUser(form:FormData){
 const {client,user}=await session();const target=text(form,'user'),confirmation=text(form,'confirmation').toLowerCase();
 if(!uuid(target)||target===user.id||!adminConfigured())finish('/utilizadores','A eliminação não está disponível para esta conta.',true);
 const {data:profile}=await client.from('profiles').select('email').eq('id',target).maybeSingle();
 // Uma conta que a eliminação antiga deixou anonimizada já não tem email: confirma-se com a palavra ELIMINAR.
 const esperado=profile?.email?profile.email.toLowerCase():'eliminar';
 if(!profile||confirmation!==esperado)finish('/utilizadores',profile?.email?'Escreva o email do utilizador para confirmar a eliminação.':'Escreva ELIMINAR para confirmar.',true);

 const {data:feito,error}=await client.rpc('eliminar_utilizador',{target});
 if(error){
  console.error(JSON.stringify({event:'rr_eliminar_falhou',codigo:error.code,erro:error.message}));
  finish('/utilizadores',error.code==='22023'?error.message:'Não foi possível eliminar. Nada foi apagado.',true);
 }
 const resultado=(feito||{}) as {caminhos?:string[];contas?:number};

 // Os ficheiros saem pelo Storage, que não deixa apagá-los por SQL.
 const caminhos=(resultado.caminhos||[]).filter(Boolean);
 let ficheirosEmFalta=0;
 for(let i=0;i<caminhos.length;i+=100){
  const {error:semFicheiros}=await adminClient().storage.from('irs-documents').remove(caminhos.slice(i,i+100));
  if(semFicheiros){ficheirosEmFalta+=caminhos.slice(i,i+100).length;console.error(JSON.stringify({event:'rr_ficheiros_por_apagar',erro:semFicheiros.message}));}
 }

 // Rede de segurança: o que ainda estiver nas pastas das contas apagadas
 // (cada conta tem a sua pasta, com uma subpasta por processo) sai também.
 const armazem=adminClient().storage.from('irs-documents');
 for(const conta of [...new Set(caminhos.map(c=>c.split('/')[0]).filter(Boolean))]){
  const {data:processos}=await armazem.list(conta,{limit:1000});
  for(const p of processos||[]){
   const {data:ficheiros}=await armazem.list(`${conta}/${p.name}`,{limit:1000});
   const restos=(ficheiros||[]).map(f=>`${conta}/${p.name}/${f.name}`);
   if(restos.length){const {error:semRestos}=await armazem.remove(restos);if(!semRestos&&ficheirosEmFalta)ficheirosEmFalta=Math.max(0,ficheirosEmFalta-restos.length);}
  }
 }

 const {error:semAuth}=await adminClient().auth.admin.deleteUser(target,false);
 if(semAuth&&!/not.?found/i.test(semAuth.message)){
  console.error(JSON.stringify({event:'rr_auth_por_apagar',erro:semAuth.message}));
  finish('/utilizadores','Os dados foram apagados, mas a autenticação não. Tente eliminar outra vez para a remover.',true);
 }
 revalidatePath('/irs');
 finish('/utilizadores',`Utilizador eliminado, com ${caminhos.length} ficheiro(s) e todos os registos.${ficheirosEmFalta?` ${ficheirosEmFalta} ficheiro(s) não saíram do armazenamento.`:''} A ficha no Cegid mantém-se.`);
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
