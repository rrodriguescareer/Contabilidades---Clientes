'use server';
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {ownerSession} from './auth';
import {adminClient,adminConfigured} from './admin-client';
import {encryptSecret} from './secret-crypto';
import {uuid} from './data';
function finish(path:string,message:string,error=false):never{revalidatePath(path);redirect(`${path}?${error?'erro':'mensagem'}=${encodeURIComponent(message)}`);}
export async function saveCompanyIntegration(form:FormData){
 const {client,user}=await ownerSession();const id=String(form.get('company')||''),credential=String(form.get('credential')||'').trim();
 if(!uuid(id)||!credential||credential.length>16384||!adminConfigured())finish('/empresas','Empresa ou credencial inválida. Confirme a configuração administrativa.',true);
 const {data}=await client.from('companies').select('id').eq('id',id).single();if(!data)finish('/empresas','Empresa indisponível.',true);
 try{const scope=`cegid:${id}`;const {error}=await adminClient().from('integration_secrets').upsert({scope,encrypted_value:encryptSecret(credential,scope),updated_at:new Date().toISOString()});if(error)throw error;}catch{finish('/empresas','Não foi possível guardar. Confirme a atualização SQL e a chave de cifragem privada.',true);}
 await adminClient().from('management_audit').insert({actor_id:user.id,action:'company_credentials_updated:'+id});
 finish('/empresas','Credencial Cegid guardada apenas para esta empresa. A integração operacional será desenvolvida posteriormente.');
}
