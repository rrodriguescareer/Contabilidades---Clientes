import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { configuration } from './lib/public-config';
export async function proxy(request: NextRequest) {
  const config=configuration();
  let response = NextResponse.next({ request });
  if (!config) return response;
  const {url,key}=config;
  const client = createServerClient(url, key, { cookies: {
    getAll: () => request.cookies.getAll(),
    setAll: values => {
      values.forEach(({name,value}) => request.cookies.set(name,value));
      response = NextResponse.next({ request });
      values.forEach(({name,value,options}) => response.cookies.set(name,value,options));
    },
  } });
  // Refresh cookies only. identity() verifies the signed claims and database permissions.
  await client.auth.getSession();
  response.headers.set('Cache-Control','private, no-store');
  return response;
}
export const config = { matcher: ['/app/:path*','/nova-password','/utilizadores','/empresas','/descontos','/pagamentos','/configuracao','/faturacao'] };
