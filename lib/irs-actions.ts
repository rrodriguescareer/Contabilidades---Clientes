'use server';
import { revalidatePath } from 'next/cache';
import { session } from './auth';
import { adminClient } from './admin-client';
import { uuid } from './data';
import {
  criarFichaCliente, emitirFaturaRecibo, guardarCredenciais, origemDasCredenciais,
  temCredenciais, testarLigacao,
} from './cegid';

/* As ações do gabinete do IRS, agora dentro da gestão. Vieram da plataforma
   do IRS com a consola; a gestão só deixa entrar quem é do gabinete (o
   session() trava o resto), e cada função da base volta a confirmá-lo. */

type Resposta = { ok: boolean; erro?: string; aviso?: string; detalhe?: string };

/** Uma vista da consola, num pedido só. */
export async function carregarGabinete(vista: string, processo: string | null) {
  const { client } = await session();
  const { data, error } = await client.rpc('espaco_gabinete', { vista, processo });
  if (error) return { dados: null, erro: error.message };
  return { dados: (data || { vista }) as Record<string, unknown> & { vista: string }, erro: null };
}

/** As contagens do menu lateral: o que espera por mim. */
export async function contagensDoGabinete() {
  const { client } = await session();
  const { data } = await client.rpc('contagens_do_gabinete');
  return (data || {}) as Record<string, number>;
}

export async function avancarProcesso(
  processo: string, destino: string, nota = '', valor = '', sentido = '',
): Promise<Resposta> {
  const { client } = await session();
  const cents = valor ? Math.round(Number(valor.replace(',', '.')) * 100) : null;
  if (destino === 'filed' && (cents == null || !Number.isFinite(cents) || cents < 0)) {
    return { ok: false, erro: 'Indique o valor apurado.' };
  }
  const { error } = await client.rpc('avancar_processo', {
    processo, destino, nota: nota.slice(0, 5000),
    valor_cents: destino === 'filed' ? cents : null,
    sentido: destino === 'filed' ? sentido : null,
  });
  if (error) return { ok: false, erro: error.message };
  revalidatePath('/irs');
  return { ok: true };
}

export async function prontidaoDoProcesso(processo: string) {
  const { client } = await session();
  const { data, error } = await client.rpc('prontidao_do_processo', { processo });
  if (error) return { dados: null, erro: error.message };
  return { dados: data as unknown[], erro: null };
}

/** A senha das Finanças. A consulta fica registada antes de a senha sair da
    base — é esse registo que o cliente vê no Acompanhamento. */
export async function verSenhaFinancas(pessoa: string) {
  const { client } = await session();
  if (!uuid(pessoa)) return { ok: false as const, erro: 'Pessoa inválida.' };
  const { data, error } = await client.rpc('consultar_senha_financas', { p_pessoa: pessoa });
  if (error || typeof data !== 'string') {
    return { ok: false as const, erro: error?.code === '22023' ? error.message : 'Não foi possível consultar a senha.' };
  }
  try {
    const { decryptSecret } = await import('./secret-crypto');
    return { ok: true as const, senha: decryptSecret(data, `financas:${pessoa}`) };
  } catch {
    return { ok: false as const, erro: 'A senha guardada não pôde ser decifrada. Peça-a outra vez ao cliente.' };
  }
}

/** Descarregar um documento do cliente, com registo da descarga. */
export async function descarregarDocumento(documento: string) {
  const { client } = await session();
  if (!uuid(documento)) return { ok: false as const, erro: 'Documento inválido.' };
  const { data: caminho, error } = await client.rpc('registar_descarga', { documento });
  if (error || typeof caminho !== 'string') {
    return { ok: false as const, erro: error?.code === '22023' ? error.message : 'Documento indisponível.' };
  }
  const { data: assinado, error: semUrl } = await client.storage
    .from('irs-documents')
    .createSignedUrl(caminho, 60, { download: true });
  if (semUrl || !assinado) return { ok: false as const, erro: 'Não foi possível abrir o documento.' };
  return { ok: true as const, url: assinado.signedUrl };
}

export async function resolverAlertaDoGabinete(alerta: string) {
  const { client } = await session();
  if (!uuid(alerta)) return { ok: false, erro: 'Alerta inválido.' };
  const { error } = await client
    .from('task_alerts')
    .update({ resolved_at: new Date().toISOString() })
    .eq('id', alerta);
  if (error) return { ok: false, erro: 'Não foi possível resolver.' };
  revalidatePath('/irs');
  return { ok: true };
}

/** Responder ao cliente, dentro do processo. */
export async function enviarMensagem(
  _anterior: { ok: boolean; erro?: string } | null, form: FormData,
): Promise<{ ok: boolean; erro?: string }> {
  const { client, user } = await session();
  const conta = String(form.get('conta') || '');
  const processo = String(form.get('processo') || '');
  const corpo = String(form.get('corpo') || '').trim().slice(0, 4000);
  if (!uuid(conta) || !uuid(processo)) return { ok: false, erro: 'Processo inválido.' };
  if (!corpo) return { ok: false, erro: 'Escreva a mensagem.' };
  const { error } = await client
    .from('messages')
    .insert({ account_id: conta, case_id: processo, body: corpo, author_id: user.id });
  if (error) return { ok: false, erro: 'Não foi possível enviar.' };
  return { ok: true };
}

/* --------------------------------------------------------------- Cegid */

/** Prova numa contestação: o que foi feito no Cegid, e quando. Falhar a
    registar não faz falhar a ação. */
async function registarCegid(tipo: string, detalhe: string, conta: string | null, processo: string) {
  const { error } = await adminClient().from('registo_atividade').insert({
    account_id: conta, case_id: processo, tipo, detalhe: detalhe.slice(0, 2000),
  });
  if (error) console.error(JSON.stringify({ event: 'rr_registo_falhou', tipo, erro: error.message }));
}

export async function estadoCegid() {
  await session();
  return { configurado: await temCredenciais(), origem: await origemDasCredenciais() };
}

export async function guardarCredenciaisCegid(form: FormData): Promise<Resposta> {
  await session();
  const id = String(form.get('identificador') || '').trim();
  const segredo = String(form.get('segredo') || '').trim();
  if (id.length < 8 || segredo.length < 8) return { ok: false, erro: 'Indique o identificador e o segredo.' };
  await guardarCredenciais(id, segredo);
  const prova = await testarLigacao();
  if (!prova.ok) return { ok: false, erro: `Guardado, mas a ligação falhou: ${prova.erro}` };
  return { ok: true, aviso: 'Credenciais guardadas e ligação confirmada.' };
}

export async function testarCegid(): Promise<Resposta> {
  await session();
  const r = await testarLigacao();
  return r.ok ? { ok: true, aviso: 'Ligação ao Cegid confirmada.' } : { ok: false, erro: r.erro };
}

async function titularDoProcesso(processo: string) {
  const admin = adminClient();
  const { data: caso } = await admin
    .from('irs_cases').select('account_id, client_accounts(name)').eq('id', processo).maybeSingle();
  if (!caso) return null;
  const { data: acessos } = await admin
    .from('account_access').select('user_id').eq('account_id', caso.account_id).eq('role', 'owner');
  const { data: perfil } = await admin
    .from('profiles')
    .select('full_name, nif, email, phone, tax_residence, birth_date, street, postal_code, locality')
    .in('id', (acessos || []).map((a) => a.user_id))
    .not('nif', 'is', null)
    .limit(1)
    .maybeSingle();
  const nome = perfil?.full_name
    || (caso as { client_accounts?: { name?: string } }).client_accounts?.name
    || 'Cliente';
  return { nome, perfil, conta: caso.account_id as string };
}

export async function criarFichaCegid(processo: string): Promise<Resposta> {
  await session();
  if (!uuid(processo)) return { ok: false, erro: 'Processo inválido.' };
  const alvo = await titularDoProcesso(processo);
  if (!alvo) return { ok: false, erro: 'Processo não encontrado.' };
  if (!alvo.perfil?.nif) return { ok: false, erro: 'O cliente ainda não tem NIF no perfil.' };
  const r = await criarFichaCliente({
    nome: alvo.nome, nif: alvo.perfil.nif, email: alvo.perfil.email, telefone: alvo.perfil.phone,
    residencia: alvo.perfil.tax_residence, nascimento: alvo.perfil.birth_date,
    rua: alvo.perfil.street, codigoPostal: alvo.perfil.postal_code, localidade: alvo.perfil.locality,
  });
  if (!r.ok) {
    await registarCegid('cegid_ficha_falhou', `NIF ${alvo.perfil.nif} · ${r.nifInvalido ? 'NIF recusado' : r.erro}`, alvo.conta, processo);
    return { ok: false, erro: r.nifInvalido ? `O Cegid recusou o NIF ${alvo.perfil.nif}. Confirme-o com o cliente.` : r.erro };
  }
  const id = (r.dados as { data?: { id?: string }; id?: string }).data?.id || (r.dados as { id?: string }).id;
  await registarCegid('cegid_ficha', `NIF ${alvo.perfil.nif}${id ? ` · cliente Cegid ${id}` : ''} · pelo gabinete`, alvo.conta, processo);
  return { ok: true, aviso: 'Ficha de cliente criada no Cegid.', detalhe: id ? `ID ${id}` : undefined };
}

export async function emitirFaturaCegid(processo: string): Promise<Resposta> {
  await session();
  if (!uuid(processo)) return { ok: false, erro: 'Processo inválido.' };
  const alvo = await titularDoProcesso(processo);
  if (!alvo) return { ok: false, erro: 'Processo não encontrado.' };
  if (!alvo.perfil?.nif) return { ok: false, erro: 'O cliente ainda não tem NIF no perfil.' };
  const { data: pago } = await adminClient()
    .from('irs_checkouts').select('amount_cents').eq('case_id', processo).eq('state', 'paid')
    .order('paid_at', { ascending: false }).limit(1).maybeSingle();
  // Sem pagamento ainda: emite-se o mínimo para provar a API.
  const total = pago?.amount_cents ?? 100;
  const r = await emitirFaturaRecibo({ nif: alvo.perfil.nif, nome: alvo.nome, descricao: 'IRS 2026', totalCents: total });
  if (!r.ok) return { ok: false, erro: r.nifInvalido ? `O Cegid recusou o NIF ${alvo.perfil.nif}.` : r.erro };
  await registarCegid('cegid_fatura', `${(total / 100).toFixed(2).replace('.', ',')} € · NIF ${alvo.perfil.nif} · em preparação`, alvo.conta, processo);
  return {
    ok: true,
    aviso: pago
      ? 'Fatura-recibo criada no Cegid, em preparação.'
      : `Fatura-recibo de teste criada (${(total / 100).toFixed(2)} €), em preparação.`,
  };
}
