'use server';
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {ownerSession} from './auth';
import {adminClient,adminConfigured} from './admin-client';
import {encryptSecret,encryptionKey} from './secret-crypto';
import {uuid} from './data';
function finish(path:string,message:string,error=false):never{revalidatePath(path);redirect(`${path}?${error?'erro':'mensagem'}=${encodeURIComponent(message)}`);}
export async function savePaymentSettings(form:FormData){
 const {user}=await ownerSession();const version=String(form.get('version')||'').trim(),key=String(form.get('merchant_key')||'').trim(),webhook=String(form.get('webhook_secret')||'').trim(),enabled=form.has('enabled');
 if(!/^\d{4}-\d{2}-\d{2}$/.test(version)||key.length>4096||webhook.length>4096||!adminConfigured())finish('/configuracao','Confirme a versão da API e a configuração administrativa.',true);
 try{encryptionKey();}catch{finish('/configuracao','Falta configurar a chave privada de cifragem nas duas aplicações.',true);}
 const admin=adminClient();
 // Disable first: partially failed credential updates must never leave charging enabled.
 const {error:disabled}=await admin.from('payment_settings').update({enabled:false,updated_at:new Date().toISOString()}).eq('id',true);
 if(disabled)finish('/configuracao','Aplique a atualização SQL antes de configurar.',true);
 for(const [scope,value]of [['revolut:merchant',key],['revolut:webhook',webhook]])if(value){const {error}=await admin.from('integration_secrets').upsert({scope,encrypted_value:encryptSecret(value,scope),updated_at:new Date().toISOString()});if(error)finish('/configuracao','Não foi possível guardar as credenciais. A cobrança ficou desativada.',true);}
 if(enabled){const {data,error}=await admin.from('integration_secrets').select('scope').in('scope',['revolut:merchant','revolut:webhook']);const scopes=new Set(data?.map(s=>s.scope));if(error||(!scopes.has('revolut:merchant')&&!process.env.REVOLUT_MERCHANT_SECRET_KEY)||(!scopes.has('revolut:webhook')&&!process.env.REVOLUT_WEBHOOK_SECRET)||!form.has('validated'))finish('/configuracao','Guarde as duas credenciais e confirme a validação da conta Merchant. A cobrança ficou desativada.',true);}
 const {error}=await admin.from('payment_settings').update({enabled,api_version:version,updated_at:new Date().toISOString()}).eq('id',true);if(error)finish('/configuracao','Não foi possível guardar. A cobrança ficou desativada.',true);
 await admin.from('management_audit').insert({actor_id:user.id,action:enabled?'payment_settings_enabled':'payment_settings_disabled'});
 finish('/configuracao','Configuração de pagamento guardada. As chaves existentes não são apresentadas no navegador.');
}
export async function saveCompanyIntegration(form:FormData){
 const {client,user}=await ownerSession();const id=String(form.get('company')||''),credential=String(form.get('credential')||'').trim();
 if(!uuid(id)||!credential||credential.length>16384||!adminConfigured())finish('/empresas','Empresa ou credencial inválida. Confirme a configuração administrativa.',true);
 const {data}=await client.from('companies').select('id').eq('id',id).single();if(!data)finish('/empresas','Empresa indisponível.',true);
 try{const scope=`cegid:${id}`;const {error}=await adminClient().from('integration_secrets').upsert({scope,encrypted_value:encryptSecret(credential,scope),updated_at:new Date().toISOString()});if(error)throw error;}catch{finish('/empresas','Não foi possível guardar. Confirme a atualização SQL e a chave de cifragem privada.',true);}
 await adminClient().from('management_audit').insert({actor_id:user.id,action:'company_credentials_updated:'+id});
 finish('/empresas','Credencial Cegid guardada apenas para esta empresa. A integração operacional será desenvolvida posteriormente.');
}
