import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {checkoutUrl,orderMatches,validWebhookSignature,revolutRequest,limitedRequestBody} from '../lib/revolut-core.ts';
test('webhooks are bounded while reading, including requests without a content length',async()=>{
 assert.equal(await limitedRequestBody(new Request('https://example.com',{method:'POST',body:'ação'}),6),'ação');
 assert.equal(await limitedRequestBody(new Request('https://example.com',{method:'POST',body:'x'.repeat(100)}),10),null);
});
test('hosted checkout refuses non-Revolut origins and credential-bearing URLs',()=>{
 assert.equal(checkoutUrl('https://checkout.revolut.com/pay/order'),'https://checkout.revolut.com/pay/order');
 for(const url of ['http://checkout.revolut.com/pay','https://checkout.revolut.com.evil.example/pay','https://checkout.revolut.com@evil.example/pay','https://user@checkout.revolut.com/pay','javascript:alert(1)','https://merchant.revolut.com:444/pay',null])assert.equal(checkoutUrl(url),null);
});
test('confirmation requires the exact order, local reference, EUR currency and integer-cent amount',()=>{
 const order={id:'order-1',state:'COMPLETED',amount:1850,currency:'EUR',merchant_order_data:{reference:'local-checkout'}};
 const expected={id:'order-1',reference:'local-checkout',amount:1850};assert.equal(orderMatches(order,expected),true);
 for(const patch of [{id:'order-2'},{amount:1851},{amount:18.5},{currency:'USD'},{merchant_order_data:{reference:'other'}}])assert.equal(orderMatches({...order,...patch},expected),false);
});
test('webhook verification rejects modified bodies, stale timestamps, missing signatures and wrong keys',()=>{
 const raw='{"event":"ORDER_COMPLETED","order_id":"order-1"}',timestamp='1792796400000',secret='local-verification-key';
 const signature='v1='+createHmac('sha256',secret).update(`v1.${timestamp}.${raw}`).digest('hex');
 assert.equal(validWebhookSignature(raw,timestamp,signature,secret,Number(timestamp)),true);
 assert.equal(validWebhookSignature(raw+' ',timestamp,signature,secret,Number(timestamp)),false);
 assert.equal(validWebhookSignature(raw,timestamp,signature,secret,Number(timestamp)+300001),false);
 assert.equal(validWebhookSignature(raw,timestamp,signature,'wrong',Number(timestamp)),false);
 assert.equal(validWebhookSignature(raw,timestamp,null,secret,Number(timestamp)),false);
});
test('API requests use only production Merchant endpoints with private authorization and an explicit version',async()=>{
 const order={id:'order-1',state:'PENDING',amount:1850,currency:'EUR'};let request;
 const fetcher=async(url,init)=>{request={url,init};return new Response(JSON.stringify(order),{status:200,headers:{'Content-Type':'application/json'}});};
 assert.deepEqual(await revolutRequest('local-secret','2024-09-01','/orders/order-1',undefined,fetcher),order);
 assert.equal(request.url,'https://merchant.revolut.com/api/orders/order-1');assert.equal(request.init.cache,'no-store');assert.equal(request.init.headers.Authorization,'Bearer local-secret');
 await assert.rejects(revolutRequest('local-secret','2024-09-01','/orders/../../evil',undefined,fetcher));
 await assert.rejects(revolutRequest('local-secret','','/orders',{},fetcher));
 await assert.rejects(revolutRequest('local-secret','2024-09-01','/orders/order-1',undefined,async()=>new Response('{}',{status:503})));
});
