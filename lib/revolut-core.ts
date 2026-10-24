import {createHmac,timingSafeEqual} from 'node:crypto';
export type RevolutOrder={id:string;state:string;amount:number;currency:string;merchant_order_data?:{reference?:string};checkout_url?:string};
export async function limitedRequestBody(request:Request,limit=65536){
 const reader=request.body?.getReader();if(!reader)return '';
 const chunks:Uint8Array[]=[];let length=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;length+=value.byteLength;if(length>limit){await reader.cancel();return null;}chunks.push(value);}}finally{reader.releaseLock();}
 return Buffer.concat(chunks,length).toString('utf8');
}
export function checkoutUrl(value:unknown){
 if(typeof value!=='string')return null;
 try{const url=new URL(value);return url.protocol==='https:'&&!url.username&&!url.password&&!url.port&&['checkout.revolut.com','merchant.revolut.com'].includes(url.hostname)?url.href:null;}catch{return null;}
}
export function orderId(value:unknown){return typeof value==='string'&&/^[a-zA-Z0-9_-]{1,120}$/.test(value);}
export function orderMatches(order:RevolutOrder,expected:{id:string;reference:string;amount:number}){
 return order.id===expected.id&&order.merchant_order_data?.reference===expected.reference&&order.amount===expected.amount&&Number.isSafeInteger(order.amount)&&order.currency==='EUR';
}
export function validWebhookSignature(raw:string,timestamp:string|null,signature:string|null,secret:string,now=Date.now()){
 if(!timestamp||!/^\d{13}$/.test(timestamp)||Math.abs(now-Number(timestamp))>300000||!signature||!secret)return false;
 const expected=createHmac('sha256',secret).update(`v1.${timestamp}.${raw}`).digest();
 return signature.split(',').some(item=>{const part=item.trim();if(!/^v1=[a-f0-9]{64}$/i.test(part))return false;const actual=Buffer.from(part.slice(3),'hex');return actual.length===expected.length&&timingSafeEqual(actual,expected);});
}
export async function revolutRequest(key:string,version:string,path:string,body?:unknown,fetcher:typeof fetch=fetch):Promise<RevolutOrder>{
 if(!key||!/^\d{4}-\d{2}-\d{2}$/.test(version)||!/^\/orders(?:\/[a-zA-Z0-9_-]{1,120})?$/.test(path))throw new Error('Payment configuration invalid');
 const response=await fetcher(`https://merchant.revolut.com/api${path}`,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json','Revolut-Api-Version':version},...(body?{body:JSON.stringify(body)}:{}),cache:'no-store',signal:AbortSignal.timeout(15000)});
 if(!response.ok)throw new Error('Payment provider unavailable');
 const order=await response.json();if(!orderId(order.id)||!Number.isSafeInteger(order.amount)||order.currency!=='EUR'||typeof order.state!=='string')throw new Error('Invalid payment response');
 return order as RevolutOrder;
}
