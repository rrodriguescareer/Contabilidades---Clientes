import 'server-only';
import {paymentConfiguration} from './payment-configuration';
import {adminClient,adminConfigured} from './admin-client';
import {orderMatches,revolutRequest} from './revolut-core';
export async function paymentsReady(){const config=await paymentConfiguration();return config.enabled&&adminConfigured()&&Boolean(config.key)&&Boolean(config.webhook)&&/^\d{4}-\d{2}-\d{2}$/.test(config.version);}
export async function reconcilePayment(id:string){
 if(!await paymentsReady())throw new Error('Payments unavailable');
 const admin=adminClient();const {data:payment,error}=await admin.from('irs_checkouts').select('id,provider_order_id,amount_cents,state').eq('id',id).single();
 if(error||!payment?.provider_order_id)throw new Error('Order unavailable');
 if(payment.state==='paid')return 'paid';
 const config=await paymentConfiguration();
 const order=await revolutRequest(config.key,config.version,`/orders/${payment.provider_order_id}`);
 if(!orderMatches(order,{id:payment.provider_order_id,reference:payment.id,amount:payment.amount_cents}))throw new Error('Payment verification mismatch');
 const {error:finished}=await admin.rpc('finish_revolut_order',{attempt:payment.id,provider_id:order.id,provider_reference:order.merchant_order_data!.reference!,provider_state:order.state.toUpperCase(),provider_amount:order.amount,provider_currency:order.currency});
 if(finished)throw new Error('Payment confirmation unavailable');
 return order.state.toUpperCase()==='COMPLETED'?'paid':order.state.toLowerCase();
}
