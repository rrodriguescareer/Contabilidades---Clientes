import type {SupabaseClient} from '@supabase/supabase-js';
import type {Profile} from './data';
export type PortalContext={id:string;email:string;email_confirmed:boolean;is_staff:boolean;profile:Profile;legal_accepted:boolean};
export async function portalContext(client:SupabaseClient,id:string){
 const {data,error}=await client.rpc('get_portal_context');
 if(!error&&data&&data.id===id)return {data:data as PortalContext,error:null};
 if(error&&!['PGRST202','42883'].includes(error.code))return {data:null,error};
 // Preserve access on installations with 005–007 while the optimisation is deployed.
 const [profile,staff,legal]=await Promise.all([
  client.from('profiles').select('*').eq('id',id).single(),client.rpc('is_staff'),
  client.from('legal_acceptances').select('id').eq('user_id',id).eq('terms_version','2026-10-23.3').eq('privacy_version','2026-10-23.3').limit(1),
 ]);
 const failure=profile.error||staff.error||legal.error;
 if(failure||!profile.data)return {data:null,error:failure||new Error('Profile unavailable')};
 return {data:{id,email:profile.data.email,email_confirmed:true,is_staff:staff.data===true,profile:profile.data,legal_accepted:Boolean(legal.data?.length)} as PortalContext,error:null};
}
