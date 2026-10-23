// Server-side configuration. Accept the public-key names used by Vercel integrations.
export function configuration() {
  const rawUrl=(process.env.NEXT_PUBLIC_SUPABASE_URL||process.env.SUPABASE_URL||'').trim();
  const key=(process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY||process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY||process.env.SUPABASE_PUBLISHABLE_KEY||process.env.SUPABASE_ANON_KEY||'').trim();
  if(!rawUrl||!key||key.startsWith('sb_secret_'))return null;
  try{
    const url=new URL(rawUrl);
    if(url.protocol!=='https:'&&process.env.NODE_ENV==='production')return null;
    if(!['http:','https:'].includes(url.protocol)||url.username||url.password)return null;
    if(!key.startsWith('sb_publishable_')){
      const payload=JSON.parse(Buffer.from(key.split('.')[1]||'','base64url').toString());
      if(payload.role!=='anon')return null;
    }
    return {url:url.origin,key};
  }catch{return null;}
}
