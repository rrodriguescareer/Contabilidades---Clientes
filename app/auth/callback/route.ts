import { NextResponse, type NextRequest } from 'next/server';
import { supabase } from '@/lib/supabase';
export async function GET(request:NextRequest){
  const code=request.nextUrl.searchParams.get('code');
  const wanted=request.nextUrl.searchParams.get('next');
  const next=wanted==='/nova-password'?'/nova-password':'/app';
  if(code){const client=await supabase();const {error}=await client.auth.exchangeCodeForSession(code);if(!error)return NextResponse.redirect(new URL(next,request.url));}
  return NextResponse.redirect(new URL('/entrar?erro=Ligação%20inválida%20ou%20expirada.',request.url));
}
