import { NextResponse, type NextRequest } from 'next/server';
import {cookies} from 'next/headers';
import type {EmailOtpType} from '@supabase/supabase-js';
import { configuration, supabase } from '@/lib/supabase';

const TIPOS=['signup','invite','recovery','email_change','email','magiclink'];

/* Porque é que o token_hash vem primeiro:
   o fluxo PKCE guarda um verificador num cookie no browser onde o registo foi
   feito. Quem se regista no computador e abre o email no telemóvel não tem
   esse cookie, e a troca do código falha — com o Supabase a dar o verify por
   bom. O token_hash não depende do dispositivo. */
export async function GET(request:NextRequest){
  if(!configuration())return falhar(request,'Serviço temporariamente indisponível.');

  const p=request.nextUrl.searchParams;
  const code=p.get('code'),hash=p.get('token_hash'),type=p.get('type');
  const wanted=p.get('next');
  const destino=wanted&&/^\/(?!\/)/.test(wanted)?wanted:null;
  const next=destino==='/nova-password'||type==='recovery'?'/nova-password'
    :(await cookies()).get('rr_invite')?'/convites/aceitar':(destino||'/app');

  // O Supabase recusa antes de nos chegar: devolve o motivo em vez de o perder.
  const recusa=p.get('error_description')||p.get('error_code')||p.get('error');
  if(recusa&&!hash&&!code){
    console.info(JSON.stringify({event:'rr_auth_callback',causa:'recusa_supabase',recusa}));
    return falhar(request,/expired/i.test(recusa)
      ?'A ligação expirou. Peça uma nova.'
      :'Ligação inválida. Peça uma nova.');
  }

  if(hash&&type&&TIPOS.includes(type)){
    const client=await supabase();
    const {error}=await client.auth.verifyOtp({token_hash:hash,type:type as EmailOtpType});
    if(!error)return NextResponse.redirect(new URL(next,request.url));
    console.info(JSON.stringify({event:'rr_auth_callback',causa:'verify_otp',erro:error.message}));
    return falhar(request,/expired|not found/i.test(error.message)
      ?'A ligação já foi usada ou expirou. Peça uma nova.'
      :'Ligação inválida. Peça uma nova.');
  }

  if(code){
    const client=await supabase();
    const {error}=await client.auth.exchangeCodeForSession(code);
    if(!error)return NextResponse.redirect(new URL(next,request.url));
    console.info(JSON.stringify({event:'rr_auth_callback',causa:'troca_codigo',erro:error.message}));
    return falhar(request,'Abra a ligação no mesmo browser onde fez o pedido, ou peça uma nova.');
  }

  console.info(JSON.stringify({event:'rr_auth_callback',causa:'sem_credencial'}));
  return falhar(request,'Ligação inválida ou expirada.');
}

function falhar(request:NextRequest,mensagem:string){
  return NextResponse.redirect(new URL(`/entrar?erro=${encodeURIComponent(mensagem)}`,request.url));
}
