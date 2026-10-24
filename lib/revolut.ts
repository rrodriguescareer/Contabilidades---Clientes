import 'server-only';
import {adminClient,adminConfigured} from './admin-client';
import {orderMatches,revolutRequest} from './revolut-core';
export function paymentsReady(){return process.env.REVOLUT_CHECKOUT_ENABLED==='true'&&adminConfigured()&&Boolean(process.env.REVOLUT_MERCHANT_SECRET_KEY)&&/^\d{4}-\d{2}-\d{2}$/.test(process.env.REVOLUT_API_VERSION||'');}
export async function reconcilePayment(id:string){
 if(!paymentsReady())throw new Error('Payments unavailable');
 const admin=adminClient();const {data:payment,error}=await admin.from('irs_checkouts').select('id,provider_order_id,amount_cents,state').eq('id',id).single();
 if(error||!payment?.provider_order_id)throw new Error('Order unavailable');
 if(payment.state==='paid')return 'paid';
 const order=await revolutRequest(process.env.REVOLUT_MERCHANT_SECRET_KEY!,process.env.REVOLUT_API_VERSION!,`/orders/${payment.provider_order_id}`);
 if(!orderMatches(order,{id:payment.provider_order_id,reference:payment.id,amount:payment.amount_cents}))throw new Error('Payment verification mismatch');
 const {error:finished}=await admin.rpc('finish_revolut_order',{attempt:payment.id,provider_id:order.id,provider_reference:order.merchant_order_data!.reference!,provider_state:order.state.toUpperCase(),provider_amount:order.amount,provider_currency:order.currency});
 if(finished)throw new Error('Payment confirmation unavailable');
 return order.state.toUpperCase()==='COMPLETED'?'paid':order.state.toLowerCase();
}
