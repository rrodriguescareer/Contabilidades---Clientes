/* A sessão da gestão é só da gestão.
 *
 * O IRS e o portal Empresas partilham uma sessão (cookies do domínio
 * .rr-contabilidade.com): quem é cliente nos dois entra uma vez. A gestão fica
 * de fora, com um cookie próprio e só deste endereço: o contabilista pode estar
 * na gestão com a sua conta e, no mesmo browser, abrir o portal do cliente com
 * outra, sem que uma entrada deite a outra abaixo. */

export const COOKIE_GESTAO = 'sb-gestao-auth-token';
const VALIDADE = 400 * 24 * 60 * 60; // a mesma do @supabase/ssr

/** As opções dos cookies de sessão para o @supabase/ssr. */
export function opcoesDosCookies() {
  return { name: COOKIE_GESTAO, path: '/', sameSite: 'lax' as const, secure: process.env.NODE_ENV === 'production', maxAge: VALIDADE };
}
