import 'server-only';
import {cache} from 'react';
import {adminClient,adminConfigured} from './admin-client';
import {decryptSecret} from './secret-crypto';
export const paymentConfiguration=cache(async()=>{
 const fallback={enabled:process.env.REVOLUT_CHECKOUT_ENABLED==='true',version:process.env.REVOLUT_API_VERSION||'',key:process.env.REVOLUT_MERCHANT_SECRET_KEY||'',webhook:process.env.REVOLUT_WEBHOOK_SECRET||''};
 if(!adminConfigured())return {...fallback,enabled:false};
 try{
 const admin=adminClient();const [{data:settings,error},{data:secrets,error:secretError}]=await Promise.all([admin.from('payment_settings').select('enabled,api_version').eq('id',true).single(),admin.from('integration_secrets').select('scope,encrypted_value').in('scope',['revolut:merchant','revolut:webhook'])]);
 if(error?.code==='42P01'||error?.code==='PGRST205')return fallback;
 if(error||secretError||!settings)return {...fallback,enabled:false};
 const read=(scope:string,backup:string)=>{const found=secrets?.find(s=>s.scope===scope);return found?decryptSecret(found.encrypted_value,scope):backup;};
 return {enabled:settings.enabled,version:settings.api_version,key:read('revolut:merchant',fallback.key),webhook:read('revolut:webhook',fallback.webhook)};
 }catch{return {...fallback,enabled:false};}
});
