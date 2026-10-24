import type {SupabaseClient} from '@supabase/supabase-js';
import type {Account,Process,Profile} from './data';
export type PortalContext={id:string;email:string;email_confirmed:boolean;is_staff:boolean;profile:Profile;legal_accepted:boolean;accounts?:Account[];cases?:Process[]};
export async function portalContext(client:SupabaseClient,id?:string){
 const {data,error}=await client.rpc('get_portal_context');
 if(!error){if(typeof data?.id==='string'&&(!id||data.id===id))return {data:data as PortalContext,error:null};return {data:null,error:new Error('Verified identity mismatch')};}
 if(error&&!['PGRST202','42883'].includes(error.code))return {data:null,error};
 // Old installations lack the verified identity RPC. Verify the user with Auth before fallback.
 const {data:verified,error:authError}=await client.auth.getUser();
 if(authError||!verified.user||(id&&verified.user.id!==id))return {data:null,error:authError||new Error('Verified identity mismatch')};
 id=verified.user.id;
 const [profile,staff,legal]=await Promise.all([
  client.from('profiles').select('*').eq('id',id).single(),client.rpc('is_staff'),
  client.from('legal_acceptances').select('id').eq('user_id',id).eq('terms_version','2026-10-23.3').eq('privacy_version','2026-10-23.3').limit(1),
 ]);
 const failure=profile.error||staff.error||legal.error;
 if(failure||!profile.data)return {data:null,error:failure||new Error('Profile unavailable')};
 return {data:{id,email:verified.user.email||'',email_confirmed:Boolean(verified.user.email_confirmed_at),is_staff:staff.data===true,profile:profile.data,legal_accepted:Boolean(legal.data?.length)} as PortalContext,error:null};
}
