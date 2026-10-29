import 'server-only';
import { adminClient, adminConfigured } from './admin-client';
import { decryptSecret, encryptSecret } from './secret-crypto';

/* O Cegid Business de cada empresa cliente (o portal Empresas).
 *
 * Diferente de lib/cegid.ts, que é a conta do próprio gabinete: aqui cada
 * empresa tem a sua conta Cegid, e as credenciais ficam cifradas no âmbito
 * cegid:<empresa>. A gestão grava-as e confirma que servem; quem as usa para
 * tirar balancetes e saldos é o portal. O formato guardado é o mesmo nos dois
 * lados: {identificador, segredo, oauth_url?, api_url?, tokens…}.
 */

const OAUTH_PADRAO = process.env.CEGID_OAUTH_URL || 'https://app2.business-pt.cegid.cloud/oauth';
const API_PADRAO = process.env.CEGID_API_URL || 'https://api2.business-pt.cegid.cloud';
const REDIRECT = process.env.CEGID_REDIRECT_URI || 'https://oauth.pstmn.io/v1/callback';
const ESCOPO = 'commercial';

export type CofreEmpresa = {
  identificador: string;
  segredo: string;
  oauth_url?: string;
  api_url?: string;
  access_token?: string;
  refresh_token?: string;
  expira_em?: number;
  exercicios?: Record<string, { token: string; expira_em: number }>;
};

const ambito = (empresa: string) => `cegid:${empresa}`;

/** Grava (ou substitui) as credenciais de uma empresa. Os tokens antigos
    deixam de servir e são esquecidos. */
export async function gravarCredenciaisEmpresa(empresa: string, dados: Pick<CofreEmpresa, 'identificador' | 'segredo' | 'oauth_url' | 'api_url'>) {
  const cofre: CofreEmpresa = {
    identificador: dados.identificador.trim(),
    segredo: dados.segredo.trim(),
    ...(dados.oauth_url ? { oauth_url: dados.oauth_url } : {}),
    ...(dados.api_url ? { api_url: dados.api_url } : {}),
  };
  const { error } = await adminClient().from('integration_secrets').upsert({
    scope: ambito(empresa),
    encrypted_value: encryptSecret(JSON.stringify(cofre), ambito(empresa)),
    updated_at: new Date().toISOString(),
  });
  if (error) throw error;
  await adminClient().from('empresa_cegid_cache').delete().eq('company_id', empresa);
}

export async function apagarCredenciaisEmpresa(empresa: string) {
  await adminClient().from('integration_secrets').delete().eq('scope', ambito(empresa));
  await adminClient().from('empresa_cegid_cache').delete().eq('company_id', empresa);
}

/** O que está guardado, sem segredos: para a gestão mostrar o estado. */
export async function estadoCredenciaisEmpresa(empresa: string) {
  if (!adminConfigured()) return { guardadas: false, identificador: null as string | null, atualizado: null as string | null, formatoAntigo: false };
  const { data } = await adminClient().from('integration_secrets').select('encrypted_value,updated_at').eq('scope', ambito(empresa)).maybeSingle();
  if (!data) return { guardadas: false, identificador: null, atualizado: null, formatoAntigo: false };
  try {
    const texto = decryptSecret(data.encrypted_value, ambito(empresa));
    try {
      const c = JSON.parse(texto) as CofreEmpresa;
      const id = c.identificador || '';
      return { guardadas: true, identificador: id ? `${id.slice(0, 4)}…${id.slice(-3)}` : null, atualizado: data.updated_at as string, formatoAntigo: false };
    } catch {
      return { guardadas: true, identificador: null, atualizado: data.updated_at as string, formatoAntigo: true };
    }
  } catch {
    return { guardadas: true, identificador: null, atualizado: data.updated_at as string, formatoAntigo: true };
  }
}

async function lerCofre(empresa: string): Promise<CofreEmpresa> {
  const { data } = await adminClient().from('integration_secrets').select('encrypted_value').eq('scope', ambito(empresa)).maybeSingle();
  if (!data?.encrypted_value) throw new Error('Esta empresa ainda não tem credenciais do Cegid.');
  const texto = decryptSecret(data.encrypted_value, ambito(empresa));
  try {
    const c = JSON.parse(texto) as CofreEmpresa;
    if (c.identificador && c.segredo) return c;
  } catch {
    const [identificador, ...resto] = texto.split(':');
    if (identificador && resto.length) return { identificador, segredo: resto.join(':') };
  }
  throw new Error('As credenciais guardadas estão no formato antigo (um só campo). Volte a gravá-las com o identificador e o segredo.');
}

async function gravarCofre(empresa: string, cofre: CofreEmpresa) {
  await adminClient().from('integration_secrets').upsert({
    scope: ambito(empresa), encrypted_value: encryptSecret(JSON.stringify(cofre), ambito(empresa)), updated_at: new Date().toISOString(),
  });
}

const oauth = (c: CofreEmpresa) => (c.oauth_url || OAUTH_PADRAO).replace(/\/$/, '');
const api = (c: CofreEmpresa) => (c.api_url || API_PADRAO).replace(/\/$/, '');

async function trocar(empresa: string, cofre: CofreEmpresa, corpo: Record<string, string>) {
  const r = await fetch(`${oauth(cofre)}/token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json',
      Authorization: 'Basic ' + Buffer.from(`${cofre.identificador}:${cofre.segredo}`).toString('base64'),
    },
    body: new URLSearchParams({ ...corpo, scope: ESCOPO }),
    cache: 'no-store',
  });
  if (!r.ok) throw new Error(`O Cegid recusou a autenticação (${r.status}). Confirme o identificador e o segredo.`);
  const d = (await r.json()) as { access_token: string; refresh_token: string; expires_in: number };
  const vida = Math.max(0, Number(d.expires_in) || 0);
  const novo: CofreEmpresa = {
    ...cofre, access_token: d.access_token, refresh_token: d.refresh_token,
    expira_em: Date.now() + (vida - Math.min(300, Math.floor(vida / 10))) * 1000, exercicios: {},
  };
  await gravarCofre(empresa, novo);
  return novo;
}

async function token(empresa: string, cofre: CofreEmpresa) {
  if (cofre.access_token && cofre.expira_em && cofre.expira_em > Date.now()) return cofre;
  if (cofre.refresh_token) {
    try { return await trocar(empresa, cofre, { grant_type: 'refresh_token', refresh_token: cofre.refresh_token }); } catch { /* de raiz */ }
  }
  const url = new URL(`${oauth(cofre)}/auth`);
  url.searchParams.set('client_id', cofre.identificador);
  url.searchParams.set('redirect_uri', REDIRECT);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', ESCOPO);
  const r = await fetch(url, { redirect: 'manual', cache: 'no-store' });
  const destino = r.headers.get('location');
  const codigo = destino ? new URL(destino, REDIRECT).searchParams.get('code') : null;
  if (codigo) return trocar(empresa, cofre, { grant_type: 'authorization_code', code: codigo });
  return trocar(empresa, cofre, { grant_type: 'client_credentials' });
}

/** Confirma que as credenciais servem: autentica e lista os exercícios. */
export async function testarCegidEmpresa(empresa: string): Promise<{ ok: true; exercicios: string[] } | { ok: false; erro: string }> {
  if (!adminConfigured()) return { ok: false, erro: 'Falta a chave de serviço do Supabase nesta aplicação.' };
  try {
    const cofre = await token(empresa, await lerCofre(empresa));
    const r = await fetch(`${api(cofre)}/fiscal_years_list`, {
      headers: { Accept: 'application/json', 'Content-Type': 'application/vnd.api+json', Authorization: `Bearer ${cofre.access_token}` },
      cache: 'no-store',
    });
    if (!r.ok) return { ok: false, erro: `O Cegid recusou a lista de exercícios (${r.status}).` };
    const corpo = (await r.json()) as { data?: { attributes?: { fiscal_year_name?: string; fiscal_year?: number } }[] };
    return { ok: true, exercicios: (corpo.data || []).map((x) => x.attributes?.fiscal_year_name || String(x.attributes?.fiscal_year ?? '')) };
  } catch (e) {
    return { ok: false, erro: (e as Error).message };
  }
}
