'use server';
import {createHash,randomBytes} from 'node:crypto';
import {cookies} from 'next/headers';
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {session,identity} from './auth';
import {siteUrl} from './supabase';
import {IS_MANAGEMENT} from './app';
import {uuid} from './data';
import {validEmail} from './validation';
import {LEGAL_VERSION,acceptedLegal} from './legal';
export type InvitationResult={error?:string;url?:string;message?:string};
export async function sendHouseholdInvitation(_:InvitationResult,form:FormData):Promise<InvitationResult>{
 const {client}=await session();const account=String(form.get('account')||''),person=String(form.get('person')||''),email=String(form.get('email')||'').trim().toLowerCase();
 if(!uuid(account)||!uuid(person)||!validEmail(email))return {error:'Indique a pessoa e um email válido.'};
 const origin=IS_MANAGEMENT?process.env.NEXT_PUBLIC_IRS_URL:siteUrl();if(!origin||!/^https:\/\//.test(origin))return {error:'O envio de convites está temporariamente indisponível.'};
 const token=randomBytes(32).toString('hex'),hash=createHash('sha256').update(token).digest('hex');
 const {data:id,error}=await client.rpc('create_household_invitation',{account,person,invited_email:email,hash});
 if(error||!id)return {error:'Não foi possível criar o convite. Confirme os acessos da conta.'};
 const url=`${new URL(origin).origin}/convite/${token}`;
 if(process.env.RESEND_API_KEY&&process.env.MAIL_FROM){
  try{
   const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${process.env.RESEND_API_KEY}`,'Content-Type':'application/json','Idempotency-Key':`irs-invitation-${id}`},body:JSON.stringify({from:process.env.MAIL_FROM,to:[email],subject:'RR - IRS - Convite para o Agregado Fiscal',text:`Foi convidado a confirmar a sua associação a um agregado fiscal no Portal IRS de Rúben Rodrigues.\n\nAbra a ligação, crie conta ou entre com este email e confirme o convite:\n${url}\n\nA ligação é válida durante sete dias. Aceitar o convite não permite consultar os dados fiscais dos outros membros. Se não reconhece o pedido, ignore esta mensagem.`,reply_to:'contabilidade.rubenrodrigues@gmail.com'}),signal:AbortSignal.timeout(15000)});
   if(!response.ok)throw new Error('Delivery failed');
   const {error:marked}=await client.rpc('mark_household_invitation',{invitation:id,new_state:'sent'});
   revalidatePath('/app');return {url,message:marked?'Email enviado. Atualize a página para verificar o estado.':'Convite enviado por email. A ligação é válida durante sete dias.'};
  }catch{await client.rpc('mark_household_invitation',{invitation:id,new_state:'failed'});return {error:'O envio por email falhou. Tente criar um novo convite.'};}
 }
 revalidatePath('/app');return {url,message:'Convite criado. O envio automático por email ainda não está disponível; copie e partilhe esta ligação com o familiar.'};
}
export async function acceptInvitation(form:FormData){
 const {client}=await identity();const token=(await cookies()).get('rr_invite')?.value;
 if(!token||!/^[a-f0-9]{64}$/.test(token))redirect('/convites/aceitar?erro=Convite%20inválido.');
 if(acceptedLegal(form)){
  const {error}=await client.rpc('record_legal_acceptance',{expected_terms:LEGAL_VERSION,expected_privacy:LEGAL_VERSION});
  if(error)redirect('/convites/aceitar?erro=Não%20foi%20possível%20registar%20a%20aceitação.');
 }
 const {error}=await client.rpc('accept_household_invitation',{token});
 if(error)redirect('/convites/aceitar?erro=Confirme%20que%20entrou%20com%20o%20email%20convidado,%20aceitou%20os%20termos%20e%20que%20a%20ligação%20não%20expirou.');
 (await cookies()).delete('rr_invite');redirect('/convites/aceite');
}
