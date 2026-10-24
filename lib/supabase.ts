import 'server-only';
import {cache} from 'react';
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

import { configuration } from './public-config';
export { configuration } from './public-config';
export const supabase=cache(async function supabase() {
  const config = configuration();
  if (!config) throw new Error('Configuração Supabase em falta.');
  const store = await cookies();
  return createServerClient(config.url, config.key, {
    global:{fetch:async(input,init)=>{
      const started=performance.now();
      try{return await fetch(input,init);}finally{
       const ms=Math.round(performance.now()-started);
       if(ms>750){const url=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url);const endpoint=url.pathname.startsWith('/auth/')?'auth':url.pathname.split('/').slice(0,5).join('/');console.info(JSON.stringify({event:'rr_backend_timing',endpoint,ms}));}
      }
    }},
    cookies: { getAll: () => store.getAll(), setAll: entries => {
      try { entries.forEach(({ name, value, options }) => store.set(name, value, options)); } catch { /* Refreshed by proxy for Server Components. */ }
    } },
  });
});
export function siteUrl() {
  const value = process.env.NEXT_PUBLIC_SITE_URL || (process.env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : '');
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost','127.0.0.1'].includes(url.hostname))) return null;
    return url.origin;
  } catch { return null; }
}
