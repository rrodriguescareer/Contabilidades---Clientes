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
  // Renova os cookies. Quem autoriza mesmo é identity(), que verifica as
  // reivindicações assinadas, e as políticas de RLS na base de dados.
  const { data } = await client.auth.getSession();

  // Sem sessão nenhuma, corta aqui. Se deixássemos a página correr, o Next já
  // teria enviado o início do HTML quando o redirect() acontecesse, e o
  // visitante via a página piscar antes de ser mandado para a entrada.
  if (!data.session?.access_token) {
    const entrada = new URL('/entrar', request.url);
    const destino = request.nextUrl.pathname + request.nextUrl.search;
    if (destino && destino !== '/entrar') entrada.searchParams.set('destino', destino);
    const saida = NextResponse.redirect(entrada);
    saida.headers.set('Cache-Control','private, no-store');
    return saida;
  }

  response.headers.set('Cache-Control','private, no-store');
  return response;
}
export const config = { matcher: ['/app/:path*','/nova-password','/utilizadores','/empresas','/descontos','/pagamentos','/configuracao','/faturacao'] };
