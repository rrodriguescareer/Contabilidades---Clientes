import 'server-only';
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

export function configuration() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  try { if (new URL(url).protocol !== 'https:' && process.env.NODE_ENV === 'production') return null; } catch { return null; }
  return { url, key };
}
export async function supabase() {
  const config = configuration();
  if (!config) throw new Error('Configuração Supabase em falta.');
  const store = await cookies();
  return createServerClient(config.url, config.key, {
    cookies: { getAll: () => store.getAll(), setAll: entries => {
      try { entries.forEach(({ name, value, options }) => store.set(name, value, options)); } catch { /* Refreshed by proxy for Server Components. */ }
    } },
  });
}
export function siteUrl() {
  const value = process.env.NEXT_PUBLIC_SITE_URL || (process.env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : '');
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost','127.0.0.1'].includes(url.hostname))) return null;
    return url.origin;
  } catch { return null; }
}
