'use server';
import {createHash} from 'node:crypto';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { session } from './auth';
import { IS_MANAGEMENT } from './app';
import { personError } from './validation';
import { uuid, categories, states, relations, documentKinds } from './data';
const text=(form:FormData,key:string,max=5000)=>String(form.get(key)||'').trim().slice(0,max);
function context(form:FormData){const account=text(form,'account'),process=text(form,'process'),view=text(form,'view');const path=`/app?conta=${encodeURIComponent(account)}&processo=${encodeURIComponent(process)}&view=${encodeURIComponent(view)}`;return{account,process,path};}
function failure(message:string,path='/app'):never{redirect(`${path}${path.includes('?')?'&':'?'}erro=${encodeURIComponent(message)}`);}
function done(path:string,message='Alteração guardada.'):never{revalidatePath('/app');redirect(`${path}&mensagem=${encodeURIComponent(message)}`);}
export async function approveClient(form:FormData){
 const {client}=await session();if(!IS_MANAGEMENT)failure('Sem permissão.');const id=text(form,'user_id'),name=text(form,'name',200),year=Number(text(form,'year'));
 if(!uuid(id)||!name||!Number.isInteger(year)||year<2000||year>2100)failure('Verifique o cliente e o ano.');
 const {data,error}=await client.rpc('approve_client',{client:id,account_name:name,year});if(error)failure('Não foi possível aprovar. O utilizador deve ter nome, nascimento e NIF completos.');
 revalidatePath('/app');redirect(`/app?conta=${data}&view=resumo&mensagem=Conta-cliente%20disponível.%20Confirme%20os%20acessos%20na%20gestão.`);
}
export async function createAnnualCase(form:FormData){
 const {client}=await session();if(!IS_MANAGEMENT)failure('Sem permissão.');
 const account=text(form,'account'),year=Number(text(form,'year'));
 if(!uuid(account)||!Number.isInteger(year)||year<2000||year>2100)failure('Selecione a conta e um ano válido.','/app?view=clientes');
 const {data,error}=await client.rpc('create_irs_case',{account,year});
 if(error||!data)failure('Não foi possível abrir o ano. Confirme que a conta e o acesso IRS do titular estão ativos e que não existem processos duplicados.','/app?view=clientes');
 done(`/app?conta=${account}&processo=${data}&view=agregado`,'Processo anual disponível. Confirme o agregado deste ano.');
}
export async function linkPerson(form:FormData){
 const {client}=await session();const c=context(form),person=text(form,'person'),relation=text(form,'relationship');
 if(!uuid(c.account)||!uuid(c.process)||!uuid(person)||!Object.hasOwn(relations,relation)||relation==='titular')failure('Selecione a pessoa e o parentesco.',c.path);
 const {error}=await client.rpc('link_case_person',{account:c.account,process:c.process,person,relation});
 if(error)failure('Não foi possível associar a pessoa. Confirme a conta, o parentesco e o estado do processo.',c.path);
 done(c.path,'Pessoa associada a este ano. Os rendimentos e documentos anteriores não são copiados.');
}
export async function updateAccess(form:FormData){const {client}=await session();if(!IS_MANAGEMENT)failure('Sem permissão.');const account=text(form,'account'),user=text(form,'user');if(!uuid(account)||!uuid(user))failure('Acesso inválido.');const {error}=await client.from('account_access').update({active:form.has('active'),irs:form.has('irs'),business:form.has('business')}).eq('account_id',account).eq('user_id',user);if(error)failure('Não foi possível alterar os acessos.');revalidatePath('/app');redirect('/app?view=clientes&mensagem=Acessos%20atualizados.');}
export async function addPerson(form:FormData){
 const {client}=await session();const c=context(form);if(!uuid(c.account)||!uuid(c.process))failure('Selecione um processo.');
 const name=text(form,'name',201),dob=text(form,'birth_date'),nif=text(form,'nif'),relation=text(form,'relationship'),email=text(form,'email',255);
 const invalid=personError(name,dob,nif,email);if(invalid)failure(invalid,c.path);
 if(!Object.hasOwn(relations,relation)||relation==='titular')failure('Escolha um parentesco válido.',c.path);
 const {error}=await client.rpc('add_case_person',{account:c.account,process:c.process,person_name:name,birth:dob,tax_id:nif,relation,person_email:email,two_factor:form.has('two_factor')});
 if(error)failure('Não foi possível adicionar. Verifique duplicados e se o processo está aberto para recolha.',c.path);done(c.path);
}
export async function updateTwoFactor(form:FormData){const {client}=await session();const c=context(form),id=text(form,'person');if(!uuid(id))failure('Pessoa inválida.',c.path);const {error}=await client.from('people').update({tax_two_factor:form.has('two_factor')}).eq('id',id).eq('account_id',c.account);if(error)failure('Não foi possível atualizar.',c.path);done(c.path,'Estado atualizado. A ativação gera um alerta para o profissional.');}
export async function requestInvitation(form:FormData){const {client}=await session();const c=context(form),person=text(form,'person'),email=text(form,'email',254);if(!uuid(person)||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))failure('Indique um email válido.',c.path);const {error}=await client.from('invitation_requests').insert({account_id:c.account,person_id:person,email});if(error)failure('Não foi possível registar. Pode já existir um pedido pendente.',c.path);done(c.path,'Pedido de convite registado para o profissional. Ainda não foi enviado qualquer email nem atribuído acesso.');}
export async function addProperty(form:FormData){const {client}=await session();const c=context(form),label=text(form,'label',100);if(!label)failure('Indique o nome do imóvel.',c.path);const {error}=await client.from('property_assets').insert({account_id:c.account,case_id:c.process,label,description:text(form,'description',1000)});if(error)failure('Não foi possível adicionar o imóvel.',c.path);done(c.path);}
export async function addIncome(form:FormData){
 const {client}=await session();const c=context(form),category=text(form,'category'),title=text(form,'title',200),mode=text(form,'mode'),person=text(form,'person'),property=text(form,'property');
 if(!Object.hasOwn(categories,category)||!title||!['documents','manual'].includes(mode))failure('Preencha os campos do rendimento.',c.path);
 const isProperty=['property_sale','property_rent'].includes(category);
 if(isProperty&&!uuid(property))failure('Escolha um imóvel. Não é necessário associar uma pessoa.',c.path);
 if(!isProperty&&category!=='deduction'&&!uuid(person))failure('Escolha a pessoa do agregado.',c.path);
 const {error}=await client.from('income_records').insert({account_id:c.account,case_id:c.process,category,title,mode,person_id:isProperty?null:person||null,property_id:isProperty?property:null,details:text(form,'details',10000)});
 if(error)failure('Não foi possível guardar. Verifique o contexto e o estado do processo.',c.path);done(c.path);
}
export async function uploadDocument(form:FormData){
 const {client,user}=await session();const c=context(form),income=text(form,'income'),kind=text(form,'kind',150),file=form.get('file');
 if(!(file instanceof File)||file.size<1||file.size>10485760)failure('Selecione um PDF, JPEG ou PNG até 10 MB.',c.path);
 let recordCategory='';
 if(income){if(!uuid(income))failure('Rendimento inválido.',c.path);const {data}=await client.from('income_records').select('category').eq('id',income).eq('case_id',c.process).eq('account_id',c.account).single();if(!data)failure('Rendimento não autorizado.',c.path);recordCategory=data.category;}
 if(!kind||(recordCategory&&!documentKinds[recordCategory]?.includes(kind)))failure('Escolha um campo documental válido.',c.path);
 const bytes=new Uint8Array(await file.arrayBuffer());let mime='';
 if(Buffer.from(bytes.slice(0,5)).toString()==='%PDF-')mime='application/pdf';
 else if(bytes[0]===255&&bytes[1]===216&&bytes[2]===255)mime='image/jpeg';
 else if(Buffer.from(bytes.slice(0,8)).equals(Buffer.from([137,80,78,71,13,10,26,10])))mime='image/png';
 if(!mime)failure('O conteúdo do ficheiro não corresponde a PDF, JPEG ou PNG.',c.path);
 const hash=createHash('sha256').update(bytes).digest('hex');
 const {data:prepared,error:metadata}=await client.rpc('prepare_irs_document',{account:c.account,process:c.process,record:income||null,doc_kind:kind,original_name:file.name.slice(0,250),mime,size_bytes:file.size,hash});
 if(metadata||!prepared)failure('Não foi possível preparar o documento. Confirme o estado do processo. Um ficheiro idêntico pode estar pendente ou rejeitado.',c.path);
 const {id,path,reused}=prepared;
 if(!reused){
  const {error:upload}=await client.storage.from('irs-documents').upload(path,bytes,{contentType:mime,upsert:false});
  if(upload)failure('O carregamento falhou. O envio ficou pendente; contacte o contabilista antes de repetir o mesmo ficheiro.',c.path);
 }
 const {error:finished}=await client.from('documents').update({state:'uploaded'}).eq('id',id);
 if(finished)failure('O ficheiro foi recebido mas falta confirmar o estado. Contacte o profissional.',c.path);done(c.path,'Documento recebido. O conteúdo fiscal ainda será revisto pelo profissional.');
}
export async function downloadDocument(form:FormData){
 const {client}=await session();const c=context(form),id=text(form,'document');if(!uuid(id))failure('Documento inválido.',c.path);
 const {data}=await client.from('documents').select('storage_path,state').eq('id',id).eq('account_id',c.account).single();
 if(!data||!['uploaded','reviewed'].includes(data.state))failure('Documento indisponível.',c.path);
 const {data:signed,error}=await client.storage.from('irs-documents').createSignedUrl(data.storage_path,60,{download:true});if(error||!signed)failure('Não foi possível abrir o documento.',c.path);redirect(signed.signedUrl);
}
export async function sendMessage(form:FormData){const {client,user}=await session();const c=context(form),body=text(form,'body');if(!body)failure('Escreva a mensagem.',c.path);const {error}=await client.from('messages').insert({account_id:c.account,case_id:c.process,body,author_id:user.id});if(error)failure('Não foi possível enviar.',c.path);done(c.path,'Mensagem enviada.');}
export async function publishProgress(form:FormData){const {client,user}=await session();const c=context(form);if(!IS_MANAGEMENT)failure('Sem permissão.',c.path);const title=text(form,'title',200),body=text(form,'body'),status=text(form,'status');if(!title||!body||!Object.hasOwn(states,status))failure('Preencha a atualização.',c.path);const {error}=await client.rpc('publish_case_progress',{account:c.account,process:c.process,event_title:title,event_body:body,new_status:status});if(error)failure('Não foi possível publicar.',c.path);done(c.path,'Atualização publicada para o cliente.');}
export async function submitReview(form:FormData){const {client}=await session();const c=context(form);const {error}=await client.rpc('submit_case',{account:c.account,process:c.process});if(error)failure('Não foi possível enviar para revisão. Confirme os dados do titular e o estado do processo.',c.path);done(c.path,'Processo enviado para revisão. A recolha fica bloqueada até o profissional pedir correções.');}
export async function resolveAlert(form:FormData){const {client}=await session();if(!IS_MANAGEMENT)failure('Sem permissão.');const {error}=await client.from('task_alerts').update({resolved_at:new Date().toISOString()}).eq('id',text(form,'alert'));if(error)failure('Não foi possível resolver.');revalidatePath('/app');redirect('/app?view=alertas&mensagem=Alerta%20resolvido.%20O%202FA%20fiscal%20continua%20ativo.');}
