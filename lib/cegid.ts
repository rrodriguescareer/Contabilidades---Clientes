import 'server-only';
import { adminClient } from './admin-client';
import { encryptSecret, decryptSecret } from './secret-crypto';

/* Integração com o Cegid Business.
 *
 * A autenticação é um authorization code flow, mas sem ecrã de autorização:
 * o /auth responde logo com 302 e o código no cabeçalho Location. Dá para
 * correr de servidor para servidor, sem ninguém à frente do browser.
 *
 * O access token dura cerca de três meses e a renovação troca também o
 * refresh token — por isso os dois têm de ser gravados a cada renovação, ou
 * a ligação morre na vez seguinte.
 */

const AMBITO = 'cegid:global';
const ESCOPO = 'commercial';

/* O próprio endereço faz parte da configuração: há mais do que um ambiente. */
const OAUTH = process.env.CEGID_OAUTH_URL || 'https://app2.business-pt.cegid.cloud/oauth';
const API = process.env.CEGID_API_URL || 'https://api2.business-pt.cegid.cloud';
const REDIRECT = process.env.CEGID_REDIRECT_URI || 'https://oauth.pstmn.io/v1/callback';

type Cofre = {
  identificador: string;
  segredo: string;
  access_token?: string;
  refresh_token?: string;
  expira_em?: number;
};

export type Resultado<T> = { ok: true; dados: T } | { ok: false; erro: string; nifInvalido?: boolean };

/* As credenciais podem vir de dois sítios, por ordem: do ambiente, para o
   escritório as configurar uma vez e não voltar lá; ou da linha cifrada, para
   quem preferir escrevê-las no gabinete. Os tokens vivem sempre na base, que
   é onde sobrevivem a um deploy. */
async function lerCofre(): Promise<Cofre | null> {
  const doAmbiente = {
    identificador: (process.env.CEGID_CLIENT_ID || '').trim(),
    segredo: (process.env.CEGID_CLIENT_SECRET || '').trim(),
  };

  const { data } = await adminClient()
    .from('integration_secrets')
    .select('encrypted_value')
    .eq('scope', AMBITO)
    .maybeSingle();

  let guardado: Partial<Cofre> = {};
  if (data?.encrypted_value) {
    try {
      guardado = JSON.parse(decryptSecret(data.encrypted_value, AMBITO)) as Cofre;
    } catch {
      guardado = {};
    }
  }

  const identificador = doAmbiente.identificador || guardado.identificador || '';
  const segredo = doAmbiente.segredo || guardado.segredo || '';
  if (!identificador || !segredo) return null;

  // Tokens de outras credenciais não servem: se mudaram, recomeça-se.
  const mesmas = guardado.identificador === identificador && guardado.segredo === segredo;
  return {
    identificador,
    segredo,
    access_token: mesmas ? guardado.access_token : undefined,
    refresh_token: mesmas ? guardado.refresh_token : undefined,
    expira_em: mesmas ? guardado.expira_em : undefined,
  };
}

async function gravarCofre(cofre: Cofre) {
  await adminClient().from('integration_secrets').upsert({
    scope: AMBITO,
    encrypted_value: encryptSecret(JSON.stringify(cofre), AMBITO),
    updated_at: new Date().toISOString(),
  });
}

/** Guarda o identificador e o segredo. Apaga os tokens: já não servem. */
export async function guardarCredenciais(identificador: string, segredo: string) {
  await gravarCofre({ identificador: identificador.trim(), segredo: segredo.trim() });
}

export async function temCredenciais() {
  return Boolean(await lerCofre());
}

/** De onde vieram, para o gabinete poder dizê-lo em vez de adivinhar. */
export async function origemDasCredenciais(): Promise<'ambiente' | 'gabinete' | 'nenhuma'> {
  if (process.env.CEGID_CLIENT_ID && process.env.CEGID_CLIENT_SECRET) return 'ambiente';
  return (await lerCofre()) ? 'gabinete' : 'nenhuma';
}

const basica = (c: Cofre) =>
  'Basic ' + Buffer.from(`${c.identificador}:${c.segredo}`).toString('base64');

async function trocarPorTokens(cofre: Cofre, corpo: Record<string, string>): Promise<Cofre> {
  const resposta = await fetch(`${OAUTH}/token`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
      Authorization: basica(cofre),
    },
    body: new URLSearchParams({ ...corpo, scope: ESCOPO }),
    cache: 'no-store',
  });
  if (!resposta.ok) {
    throw new Error(`O Cegid recusou a autenticação (${resposta.status}).`);
  }
  const dados = (await resposta.json()) as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };
  /* A margem é proporcional, não fixa. A documentação dá um exemplo com
     7890000 segundos, mas o que a conta devolve são 14400 — quatro horas.
     Uma margem fixa de um dia fazia o token nascer expirado. */
  const vida = Math.max(0, Number(dados.expires_in) || 0);
  const margem = Math.min(300, Math.floor(vida / 10));
  const novo: Cofre = {
    ...cofre,
    access_token: dados.access_token,
    refresh_token: dados.refresh_token,
    expira_em: Date.now() + (vida - margem) * 1000,
  };
  await gravarCofre(novo);
  return novo;
}

/** Autoriza de raiz: pede o código e troca-o por tokens. */
async function autorizar(cofre: Cofre): Promise<Cofre> {
  const url = new URL(`${OAUTH}/auth`);
  url.searchParams.set('client_id', cofre.identificador);
  url.searchParams.set('redirect_uri', REDIRECT);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', ESCOPO);

  // O código vem no Location do 302. Seguir o redirecionamento perdia-o.
  const resposta = await fetch(url, { redirect: 'manual', cache: 'no-store' });
  const destino = resposta.headers.get('location');
  if (!destino) {
    throw new Error('O Cegid não devolveu o código de autorização. Confirme o identificador e o endereço de redirecionamento.');
  }
  const codigo = new URL(destino, REDIRECT).searchParams.get('code');
  if (!codigo) throw new Error('O Cegid respondeu sem código de autorização.');
  return trocarPorTokens(cofre, { grant_type: 'authorization_code', code: codigo });
}

async function token(): Promise<Cofre> {
  const cofre = await lerCofre();
  if (!cofre?.identificador || !cofre?.segredo) {
    throw new Error('Faltam as credenciais do Cegid. Configure-as no gabinete.');
  }
  if (cofre.access_token && cofre.expira_em && cofre.expira_em > Date.now()) return cofre;
  if (cofre.refresh_token) {
    try {
      return await trocarPorTokens(cofre, {
        grant_type: 'refresh_token',
        refresh_token: cofre.refresh_token,
      });
    } catch {
      // Refresh gasto ou revogado: volta-se a autorizar de raiz.
    }
  }
  return autorizar(cofre);
}

type Pedido = { metodo?: string; corpo?: unknown; jsonApi?: boolean };

async function chamar<T>(caminho: string, { metodo = 'GET', corpo, jsonApi }: Pedido = {}): Promise<Resultado<T>> {
  let cofre: Cofre;
  try {
    cofre = await token();
  } catch (erro) {
    return { ok: false, erro: (erro as Error).message };
  }

  const enviar = (acesso: string) =>
    fetch(`${API}${caminho}`, {
      method: metodo,
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${acesso}`,
        ...(corpo ? { 'Content-Type': jsonApi ? 'application/vnd.api+json' : 'application/json' } : {}),
      },
      body: corpo ? JSON.stringify(corpo) : undefined,
      cache: 'no-store',
    });

  let resposta = await enviar(cofre.access_token!);
  // 401 com token que julgávamos bom: renova uma vez e repete.
  if (resposta.status === 401) {
    try {
      const renovado = await autorizar(cofre);
      resposta = await enviar(renovado.access_token!);
    } catch (erro) {
      return { ok: false, erro: (erro as Error).message };
    }
  }

  const texto = await resposta.text();
  if (!resposta.ok) {
    return { ok: false, erro: mensagemDeErro(resposta.status, texto), nifInvalido: pareceNifInvalido(texto) };
  }
  try {
    return { ok: true, dados: (texto ? JSON.parse(texto) : {}) as T };
  } catch {
    return { ok: false, erro: 'O Cegid respondeu num formato inesperado.' };
  }
}

/* A documentação não descreve o formato dos erros, por isso lê-se o que vier
   com cuidado em vez de assumir uma forma. */
function mensagemDeErro(estado: number, texto: string): string {
  try {
    const corpo = JSON.parse(texto) as Record<string, unknown>;
    const erros = corpo.errors;
    if (Array.isArray(erros) && erros.length > 0) {
      const primeiro = erros[0] as Record<string, unknown>;
      const detalhe = primeiro.detail || primeiro.title || primeiro.message;
      if (typeof detalhe === 'string') return detalhe;
    }
    for (const campo of ['message', 'error', 'detail']) {
      if (typeof corpo[campo] === 'string') return corpo[campo] as string;
    }
  } catch {
    /* não era JSON */
  }
  return `O Cegid recusou o pedido (${estado}).`;
}

const pareceNifInvalido = (texto: string) =>
  /tax_registration_number|nif|contribuinte/i.test(texto) &&
  /inv[aá]lid|valid|incorre/i.test(texto);

/* ------------------------------------------------------------ operações */

export async function testarLigacao(): Promise<Resultado<unknown>> {
  // Um pedido pequeno só para provar que o token serve.
  return chamar('/customers?page[size]=1');
}

export type FichaCliente = {
  nome: string;
  nif: string | null;
  email?: string | null;
  telefone?: string | null;
  /** Continente, Açores ou Madeira mudam o código de país. */
  residencia?: string | null;
  nascimento?: string | null;
  rua?: string | null;
  codigoPostal?: string | null;
  localidade?: string | null;
};

const PAIS: Record<string, string> = { acores: 'PT-AC', madeira: 'PT-MA' };

export async function criarFichaCliente(ficha: FichaCliente) {
  const criada = await chamar<{ data?: { id?: string }; id?: string }>('/customers', {
    metodo: 'POST',
    jsonApi: true,
    corpo: {
      data: {
        type: 'customers',
        attributes: {
          business_name: ficha.nome,
          ...(ficha.nif ? { tax_registration_number: ficha.nif } : {}),
          ...(ficha.email ? { email: ficha.email } : {}),
          ...(ficha.telefone ? { phone_number: ficha.telefone } : {}),
          ...(ficha.nascimento ? { observations: `Data de nascimento: ${ficha.nascimento}` } : {}),
          country_iso_alpha_2: PAIS[ficha.residencia || ''] || 'PT',
        },
      },
    },
  });
  if (!criada.ok) return criada;

  /* A morada não entra na criação: o Cegid cria uma sede automaticamente e
     manda alterá-la pelos endereços. Falhar aqui não invalida a ficha, por
     isso o resultado da criação é o que conta. */
  const id = criada.dados?.data?.id || criada.dados?.id;
  if (id && (ficha.rua || ficha.codigoPostal || ficha.localidade)) {
    await chamar(`/customers/${id}/addresses`, {
      metodo: 'POST',
      jsonApi: true,
      corpo: {
        data: {
          type: 'addresses',
          attributes: {
            address: ficha.rua || '',
            postal_code: ficha.codigoPostal || '',
            city: ficha.localidade || '',
            country_iso_alpha_2: PAIS[ficha.residencia || ''] || 'PT',
          },
        },
      },
    });
  }
  return criada;
}

export type Fatura = { nif: string; nome: string; descricao: string; totalCents: number };

/** A fatura-recibo fica em preparação: o fecho é feito no Cegid. */
export async function emitirFaturaRecibo(fatura: Fatura) {
  return chamar<Record<string, unknown>>('/v1/commercial_sales_documents', {
    metodo: 'POST',
    jsonApi: true,
    corpo: {
      document_type: 'FR',
      customer_tax_registration_number: fatura.nif,
      customer_business_name: fatura.nome,
      customer_country: 'PT',
      vat_included_prices: true,
      finalize: false,
      lines: [
        {
          description: fatura.descricao,
          quantity: 1,
          unit_price: fatura.totalCents / 100,
          tax_code: 'NOR',
        },
      ],
    },
  });
}

/** O id do documento na resposta do Cegid (JSON:API ou plano). */
export function idDoDocumento(dados: unknown): string | null {
  const d = dados as { data?: { id?: string | number }; id?: string | number } | null;
  const id = d?.data?.id ?? d?.id;
  return id == null ? null : String(id);
}

/* Nota de crédito, em rascunho (finalize: false): fica em preparação no Cegid
   para ser revista e finalizada lá. Liga-se à fatura-recibo de origem pelo id
   interno do Cegid, quando se sabe, ou pela referência escrita (ex.: FR 2026/12). */
export async function emitirNotaCredito(nota: {
  nif: string; nome: string; descricao: string; totalCents: number; motivo: string;
  origemId?: string | null; origemRef?: string | null;
}) {
  const origem = nota.origemId
    ? { parent_documents_ids: [nota.origemId] }
    : nota.origemRef ? { parent_document_reference: nota.origemRef } : {};
  return chamar<Record<string, unknown>>('/v1/commercial_sales_documents', {
    metodo: 'POST',
    jsonApi: true,
    corpo: {
      document_type: 'NC',
      ...origem,
      customer_tax_registration_number: nota.nif,
      customer_business_name: nota.nome,
      customer_country: 'PT',
      vat_included_prices: true,
      finalize: false,
      notes: `Motivo: ${nota.motivo}`.slice(0, 500),
      lines: [
        { description: nota.descricao, quantity: 1, unit_price: nota.totalCents / 100, tax_code: 'NOR' },
      ],
    },
  });
}
