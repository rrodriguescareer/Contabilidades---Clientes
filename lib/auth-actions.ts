'use server';
import { redirect } from 'next/navigation';
import {signInError} from './auth-errors';
import { supabase, siteUrl } from './supabase';
import { IS_MANAGEMENT } from './app';
import {senhaComprometida,AVISO_SENHA_COMPROMETIDA} from './password-leak';
const text = (form: FormData, name: string) => String(form.get(name) || '').trim();
function error(message: string, path='/entrar'): never { redirect(`${path}?erro=${encodeURIComponent(message)}`); }
export async function signIn(form:FormData){
 const email=text(form,'email').toLowerCase(),password=String(form.get('password')||'');
 if(!email||!password)error('Preencha o email e a palavra-passe.');
 const client=await supabase();
 const started=performance.now();
 const {data:auth,error:failure}=await client.auth.signInWithPassword({email,password});
 console.info(JSON.stringify({event:'rr_login_timing',stage:'password',ms:Math.round(performance.now()-started)}));
 if(failure||!auth.user)error(signInError(failure?.code));
 // The protected destination verifies database permissions once using session().
 // Avoid a duplicate context lookup before and after this redirect.
 // Volta ao que o visitante tentou abrir, desde que seja um caminho desta
 // aplicação: '//exemplo.pt' sairia daqui para fora.
 const pedido=text(form,'destino');
 const interno=/^\/(?!\/)/.test(pedido)?pedido:'';
 redirect(interno||'/app');
}
export async function signUp(form: FormData) {
  if (IS_MANAGEMENT) error('O registo de profissionais é feito pela administração.');
  const email=text(form,'email'),password=String(form.get('password')||''),name=text(form,'full_name'),nif=text(form,'nif'),dob=text(form,'birth_date'),phone=text(form,'phone'),address=text(form,'address');
  if (!name || !/^\d{9}$/.test(nif) || !/^\d{4}-\d{2}-\d{2}$/.test(dob) || !phone || !address || password.length<12 || password.length>128 || !form.has('consent')) error('Preencha todos os campos, confirme a autorização e use uma palavra-passe com 12 ou mais caracteres.','/registar');
  const origin=siteUrl();if (!origin) error('Falta configurar NEXT_PUBLIC_SITE_URL para confirmar o email.','/registar');
  const client=await supabase();
  const {error: failure}=await client.auth.signUp({email,password,options:{emailRedirectTo:`${origin}/auth/callback?next=/app`,data:{full_name:name,nif,birth_date:dob,phone,address}}});
  if (failure) error('Não foi possível concluir o registo. Verifique os dados ou tente recuperar o acesso.','/registar');
  redirect('/entrar?mensagem=Confirme%20o%20email%20para%20continuar.%20O%20acesso%20ao%20IRS%20será%20aprovado%20pelo%20profissional.');
}
export async function signOut() { const client=await supabase();await client.auth.signOut();redirect('/entrar'); }
export async function recover(form: FormData) {
  if(process.env.AUTH_EMAIL_BRANDING_READY!=='true')error('A recuperação por email está temporariamente indisponível. Contacte o responsável.','/recuperar');
  const origin=siteUrl();if (!origin) error('Falta configurar o endereço público da aplicação.','/recuperar');
  const client=await supabase();
  await client.auth.resetPasswordForEmail(text(form,'email'),{redirectTo:`${origin}/auth/callback?next=/nova-password`});
  redirect('/entrar?mensagem=Se%20existir%20uma%20conta%20associada,%20receberá%20instruções%20para%20recuperar%20o%20acesso.');
}
export async function changePassword(form: FormData) {
  const password=String(form.get('password')||'');if(password.length<12||password.length>128)error('Use pelo menos 12 caracteres.','/nova-password');
  if(await senhaComprometida(password))error(AVISO_SENHA_COMPROMETIDA,'/nova-password');
  const client=await supabase();const {data:{user}}=await client.auth.getUser();if(!user)error('Abra uma ligação de recuperação válida.');
  const {error: failure}=await client.auth.updateUser({password});if(failure)error('Não foi possível alterar a palavra-passe.','/nova-password');
  redirect('/app');
}
