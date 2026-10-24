'use server';
import {redirect} from 'next/navigation';
import {ownerSession as session} from './auth';
import {adminClient} from './admin-client';
import {paymentConfiguration} from './payment-configuration';
import {reconcilePayment,paymentsReady} from './revolut';
import {revolutRequest,orderId,orderMatches,checkoutUrl} from './revolut-core';
import {uuid} from './data';
function done(message:string,error=false):never{redirect(`/pagamentos?${error?'erro':'mensagem'}=${encodeURIComponent(message)}`);}
export async function verifyPayment(form:FormData){
 const {client}=await session();const id=String(form.get('checkout')||'');if(!uuid(id))done('Tentativa inválida.',true);
 const {data:payment}=await client.from('irs_checkouts').select('id').eq('id',id).single();if(!payment)done('Pagamento indisponível.',true);
 try{await reconcilePayment(id);}catch{done('Não foi possível verificar a ordem na Revolut.',true);}done('Estado verificado diretamente na Revolut.');
}
export async function recoverPayment(form:FormData){
 const {client}=await session();const id=String(form.get('checkout')||''),provider=String(form.get('order_id')||'').trim();
 if(!uuid(id)||!orderId(provider)||!await paymentsReady())done('Verifique a ordem e a configuração privada da Revolut nesta aplicação.',true);
 const {data:payment}=await client.from('irs_checkouts').select('id,amount_cents,state').eq('id',id).single();if(!payment||!['creating','unknown'].includes(payment.state))done('A tentativa não pode ser recuperada por esta opção.',true);
 try{
  const config=await paymentConfiguration();
  const order=await revolutRequest(config.key,config.version,`/orders/${provider}`);
  if(!orderMatches(order,{id:provider,reference:payment.id,amount:payment.amount_cents}))done('A referência, valor ou moeda da ordem não corresponde a este processo.',true);
  const {error}=await adminClient().rpc('attach_revolut_order',{attempt:id,provider_id:provider,provider_url:checkoutUrl(order.checkout_url)});if(error)throw new Error();
  await reconcilePayment(id);
 }catch{done('Não foi possível recuperar esta tentativa. Nenhum pagamento foi marcado manualmente como recebido.',true);}
 done('Ordem associada e estado verificado na Revolut.');
}
export async function releaseUnknownPayment(form:FormData){
 const {client,user}=await session();const id=String(form.get('checkout')||'');
 if(!uuid(id)||form.get('confirmation')!=='SEM PAGAMENTO'||!form.has('checked'))done('Confirme a verificação na conta Merchant antes de libertar a tentativa.',true);
 // This is an explicit operational decision by the sole accountant, never a client action.
 const {data:payment}=await client.from('irs_checkouts').select('id,provider_order_id,state').eq('id',id).single();
 if(!payment||payment.provider_order_id||!['creating','unknown'].includes(payment.state))done('Esta tentativa deve ser verificada pela API da Revolut.',true);
 let admin;try{admin=adminClient();}catch{done('Falta a configuração administrativa privada.',true);}
 const {error}=await admin.from('irs_checkouts').update({state:'failed'}).eq('id',id).is('provider_order_id',null).in('state',['creating','unknown']);if(error)done('Não foi possível libertar.',true);
 const {error:audit}=await admin.from('management_audit').insert({actor_id:user.id,action:'checkout_released_after_merchant_verification:'+id});
 if(audit)done('Tentativa libertada; não foi possível guardar o registo de auditoria.',true);done('Tentativa libertada após a sua confirmação de ausência de cobrança.');
}
