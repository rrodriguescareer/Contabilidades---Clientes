import type { NextRequest, NextResponse } from 'next/server';

/* Uma só sessão para irs., portal. e gestao.rr-contabilidade.com.
 *
 * Os cookies de sessão do Supabase (sb-…) passam a ser do domínio
 * .rr-contabilidade.com, e por isso valem nos três subdomínios. Fora desse
 * domínio (localhost, *.vercel.app) ficam como sempre: só do próprio
 * endereço. Os cookies antigos, só deste subdomínio, são apagados quando
 * aparecem, para não haver duas versões da mesma sessão.
 *
 * Este ficheiro é igual nas três aplicações. */

const DOMINIO = 'rr-contabilidade.com';
const VALIDADE = 400 * 24 * 60 * 60; // a mesma do @supabase/ssr

export function dominioDosCookies(host: string | null | undefined) {
  const h = (host || '').split(':')[0].toLowerCase();
  return h === DOMINIO || h.endsWith(`.${DOMINIO}`) ? `.${DOMINIO}` : undefined;
}

/** As opções dos cookies de sessão para o @supabase/ssr. */
export function opcoesDosCookies(host: string | null | undefined) {
  const dominio = dominioDosCookies(host);
  return dominio ? { domain: dominio, path: '/', sameSite: 'lax' as const, secure: true, maxAge: VALIDADE } : undefined;
}

/** No proxy, no fim: reescreve os cookies de sessão para o domínio partilhado
    e apaga as cópias antigas deste subdomínio. Tem de ser a última coisa a
    mexer em Set-Cookie, porque response.cookies reescreve esses cabeçalhos. */
export function partilharCookiesDeSessao(request: NextRequest, response: NextResponse) {
  const dominio = dominioDosCookies(request.headers.get('host'));
  if (!dominio) return response;
  const nomes = (request.headers.get('cookie') || '').split(';')
    .map((c) => c.trim().split('=')[0])
    .filter((n) => n.startsWith('sb-'));
  if (!nomes.length) return response;
  const vezes = new Map<string, number>();
  for (const n of nomes) vezes.set(n, (vezes.get(n) || 0) + 1);
  const jaDefinidos = new Set(response.cookies.getAll().map((c) => c.name));
  // Com uma só cópia, passa-a para o domínio partilhado. Com duas (a antiga
  // deste subdomínio e a nova partilhada), não se sabe qual é qual: apaga-se
  // só a antiga e a partilhada fica.
  for (const [nome, n] of vezes) {
    const valor = request.cookies.get(nome)?.value;
    if (n === 1 && valor && !jaDefinidos.has(nome)) {
      response.cookies.set(nome, valor, { domain: dominio, path: '/', sameSite: 'lax', secure: true, maxAge: VALIDADE });
    }
  }
  for (const nome of vezes.keys()) {
    response.headers.append('Set-Cookie', `${nome}=; Path=/; Max-Age=0; Secure; SameSite=Lax`);
  }
  return response;
}
