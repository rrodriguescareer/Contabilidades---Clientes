import 'server-only';
import {cache} from 'react';
import {redirect} from 'next/navigation';
import {configuration,supabase} from './supabase';
import {IS_MANAGEMENT} from './app';
import {portalContext} from './portal-context';
export const identity=cache(async function identity(){
 if(!configuration())redirect('/entrar');
 const client=await supabase();
 // getSession only retrieves the token. PostgREST validates its signature and expiry.
 // get_portal_context derives the identity from auth.uid(), never from cookie metadata.
 const {data:stored,error}=await client.auth.getSession();
 if(error||!stored.session?.access_token)redirect('/entrar');
 const {data:context,error:contextError}=await portalContext(client);
 if(contextError||!context)redirect('/entrar?erro=Não%20foi%20possível%20carregar%20a%20conta.%20Verifique%20a%20atualização%20da%20base%20de%20dados.');
 if(context.profile.disabled_at||context.profile.deleted_at)redirect('/entrar?erro=Acesso%20bloqueado.%20Contacte%20o%20contabilista.');
 if(!context.email_confirmed)redirect('/entrar?erro=Confirme%20o%20seu%20email%20para%20continuar.');
 return {client,user:{id:context.id,email:context.email},context};
});
export const session=cache(async function session(){
 const current=await identity();
 if(IS_MANAGEMENT&&!current.context.is_staff)redirect('/entrar?erro=A%20conta%20está%20autenticada,%20mas%20não%20tem%20autorização%20de%20gestão.%20Verifique%20a%20configuração%20do%20contabilista%20no%20Supabase.');
 if(!IS_MANAGEMENT){
  if(current.context.is_staff){const url=process.env.NEXT_PUBLIC_GESTAO_URL;if(url&&/^https:\/\//.test(url))redirect(url);redirect('/contabilista');}
  if(!current.context.legal_accepted)redirect('/aceitar-termos');
  if(!current.context.profile.onboarding_completed_at)redirect('/onboarding');
 }
 return current;
});

export async function ownerSession(){
 const current=await session();
 if(current.context.email.toLowerCase()!=='contabilidade.rubenrodrigues@gmail.com')redirect('/app?erro=Apenas%20o%20administrador%20pode%20gerir%20este%20módulo.');
 return current;
}
