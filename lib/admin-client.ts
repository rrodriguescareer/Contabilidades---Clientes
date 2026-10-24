import 'server-only';
import {createClient} from '@supabase/supabase-js';
import {configuration} from './public-config';
export function adminConfigured(){return Boolean(configuration()&&(process.env.SUPABASE_SECRET_KEY||process.env.SUPABASE_SERVICE_ROLE_KEY));}
export function adminClient(){
 const config=configuration(),key=process.env.SUPABASE_SECRET_KEY||process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!config||!key)throw new Error('Serviço administrativo indisponível.');
 return createClient(config.url,key,{auth:{autoRefreshToken:false,persistSession:false}});
}
