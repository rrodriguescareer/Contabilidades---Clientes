import { NextResponse, type NextRequest } from 'next/server';
import {cookies} from 'next/headers';
import type {EmailOtpType} from '@supabase/supabase-js';
import { configuration, supabase } from '@/lib/supabase';
export async function GET(request:NextRequest){
  if(!configuration())return NextResponse.redirect(new URL('/entrar?erro=Serviço%20temporariamente%20indisponível.',request.url));
  const code=request.nextUrl.searchParams.get('code'),hash=request.nextUrl.searchParams.get('token_hash'),type=request.nextUrl.searchParams.get('type');
  const wanted=request.nextUrl.searchParams.get('next');
  const next=wanted==='/nova-password'||type==='recovery'?'/nova-password':(await cookies()).get('rr_invite')?'/convites/aceitar':'/app';
  if(code){const client=await supabase();const {error}=await client.auth.exchangeCodeForSession(code);if(!error)return NextResponse.redirect(new URL(next,request.url));}
  if(hash&&type&&['signup','invite','recovery','email_change','email'].includes(type)){const client=await supabase();const {error}=await client.auth.verifyOtp({token_hash:hash,type:type as EmailOtpType});if(!error)return NextResponse.redirect(new URL(next,request.url));}
  return NextResponse.redirect(new URL('/entrar?erro=Ligação%20inválida%20ou%20expirada.',request.url));
}
