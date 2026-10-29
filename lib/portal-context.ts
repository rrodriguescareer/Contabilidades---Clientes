import type {SupabaseClient} from '@supabase/supabase-js';
import type {Account,Process,Profile} from './data';
export type PortalContext={id:string;email:string;email_confirmed:boolean;is_staff:boolean;profile:Profile;legal_accepted:boolean;accounts?:Account[];cases?:Process[]};
/** A identidade verificada, numa só chamada: o get_portal_context deriva tudo
    de auth.uid() e diz se a versão em vigor dos Termos está aceite. */
export async function portalContext(client:SupabaseClient,id?:string){
 const {data,error}=await client.rpc('get_portal_context');
 if(error)return {data:null,error};
 if(typeof data?.id==='string'&&(!id||data.id===id))return {data:data as PortalContext,error:null};
 return {data:null,error:new Error('Verified identity mismatch')};
}
