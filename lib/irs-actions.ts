'use server';
import { revalidatePath } from 'next/cache';
import { session } from './auth';
import { adminClient } from './admin-client';
import { uuid } from './data';
import {
  criarFichaCliente, emitirFaturaRecibo, emitirNotaCredito, faturasDoCliente, guardarCredenciais, idDoDocumento,
  origemDasCredenciais, temCredenciais, testarLigacao, type FaturaCegid,
} from './cegid';
import { expirarSessao, reembolsarNaStripe } from './stripe-gestao';
import { enviarEmail, eurosTexto, PORTAL, primeiroNome } from './email';

/* As ações do gabinete do IRS, agora dentro da gestão. Vieram da plataforma
   do IRS com a consola; a gestão só deixa entrar quem é do gabinete (o
   session() trava o resto), e cada função da base volta a confirmá-lo. */

type Resposta = {
  ok: boolean; erro?: string; aviso?: string; detalhe?: string;
  /** Para a notificação: um título curto e uma linha por integração. */
  titulo?: string; detalhes?: string[]; tom?: 'ok' | 'atencao';
};

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
  await avisarEtapa(processo, destino, nota, cents, sentido);
  revalidatePath('/irs');
  return { ok: true };
}

/* As etapas que o cliente precisa de saber por email. As outras ficam no
   acompanhamento, sem encher a caixa de correio. */
async function avisarEtapa(processo: string, destino: string, nota: string, cents: number | null, sentido: string) {
  const alvo = await titularDoProcesso(processo);
  if (!alvo?.perfil?.email) return;
  const ola = `Olá${primeiroNome(alvo.nome) ? `, ${primeiroNome(alvo.nome)}` : ''}.`;
  const botao = { texto: 'Ver o acompanhamento', url: `${PORTAL}/app?separador=progresso` };
  const textos: Record<string, { assunto: string; titulo: string; paragrafos: string[]; destaque?: { rotulo: string; valor: string } }> = {
    returned: {
      assunto: 'O seu processo de IRS foi devolvido para correção',
      titulo: 'Faltam elementos no seu processo',
      paragrafos: [ola, 'O processo foi devolvido para correção. Complete o que é pedido e volte a submeter no portal.',
        ...(nota.trim() ? [`Nota do contabilista: ${nota.trim()}`] : [])],
    },
    filed: {
      assunto: 'A sua declaração de IRS foi entregue',
      titulo: 'Declaração entregue na Autoridade Tributária',
      paragrafos: [ola, 'A declaração de IRS foi entregue na Autoridade Tributária. Segue-se a validação e a liquidação, que acompanhamos por si.'],
      ...(cents != null ? { destaque: { rotulo: sentido === 'refund' ? 'Reembolso apurado' : 'Imposto a pagar', valor: eurosTexto(cents) } } : {}),
    },
    assessed: {
      assunto: 'A liquidação do seu IRS foi emitida',
      titulo: 'Liquidação emitida',
      paragrafos: [ola, 'A Autoridade Tributária emitiu a liquidação do seu IRS. O valor apurado está confirmado no portal.'],
    },
    closed: {
      assunto: 'O seu processo de IRS está concluído',
      titulo: 'Processo concluído',
      paragrafos: [ola, 'O seu processo de IRS está concluído. Obrigado pela confiança. Os documentos continuam disponíveis no portal.'],
    },
  };
  const t = textos[destino];
  if (!t) return;
  await enviarEmail({
    chave: `etapa:${processo}:${destino}:${new Date().toISOString().slice(0, 16)}`,
    para: alvo.perfil.email, ...t, botao, conta: alvo.conta, processo,
  });
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
  const { data: msg, error } = await client
    .from('messages')
    .insert({ account_id: conta, case_id: processo, body: corpo, author_id: user.id })
    .select('id').single();
  if (error) return { ok: false, erro: 'Não foi possível enviar.' };
  const alvo = await titularDoProcesso(processo);
  if (alvo?.perfil?.email && msg?.id) {
    await enviarEmail({
      chave: `mensagem:${msg.id}`, para: alvo.perfil.email,
      assunto: 'Tem uma nova mensagem sobre o seu IRS',
      titulo: 'Nova mensagem do contabilista',
      paragrafos: [`Olá${primeiroNome(alvo.nome) ? `, ${primeiroNome(alvo.nome)}` : ''}.`,
        corpo.length > 600 ? `${corpo.slice(0, 600)}…` : corpo],
      botao: { texto: 'Responder no portal', url: `${PORTAL}/app?separador=mensagens` },
      conta, processo,
    });
  }
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
    .from('irs_checkouts').select('id, amount_cents').eq('case_id', processo).eq('state', 'paid')
    .eq('tipo', 'preparacao').order('paid_at', { ascending: false }).limit(1).maybeSingle();
  // Sem pagamento ainda: emite-se o mínimo para provar a API.
  const total = pago?.amount_cents ?? 100;
  const r = await emitirFaturaRecibo({ nif: alvo.perfil.nif, nome: alvo.nome, descricao: 'IRS 2026', totalCents: total });
  if (!r.ok) return { ok: false, erro: r.nifInvalido ? `O Cegid recusou o NIF ${alvo.perfil.nif}.` : r.erro };
  // O id fica no pagamento: é por ele que uma nota de crédito se liga a esta fatura.
  const documento = idDoDocumento(r.dados);
  if (pago && documento) await (await session()).client.rpc('guardar_cegid_do_pagamento', { p_checkout: pago.id, p_documento: documento });
  await registarCegid('cegid_fatura', `${(total / 100).toFixed(2).replace('.', ',')} € · NIF ${alvo.perfil.nif} · em preparação`, alvo.conta, processo);
  return {
    ok: true,
    aviso: pago
      ? 'Fatura-recibo criada no Cegid, em preparação.'
      : `Fatura-recibo de teste criada (${(total / 100).toFixed(2)} €), em preparação.`,
  };
}

/* ------------------------------------------- reembolsos e pagamentos extra */

const euros = (c: number) => (c / 100).toFixed(2).replace('.', ',') + ' €';
const centimos = (texto: string) => {
  const n = Number(String(texto || '').replace(/\s|€/g, '').replace(',', '.'));
  return Number.isFinite(n) ? Math.round(n * 100) : NaN;
};

/** Reembolso parcial ou total. Primeiro o dinheiro (Stripe), depois o
    documento (nota de crédito em rascunho no Cegid). Se o Cegid falhar, o
    reembolso fica feito e a nota pode ser criada outra vez. */
export async function reembolsar(checkout: string, valor: string, motivo: string, origemRef = '', origemId = ''): Promise<Resposta> {
  const { client } = await session();
  if (!uuid(checkout)) return { ok: false, erro: 'Pagamento inválido.' };
  const cents = centimos(valor);
  if (!Number.isInteger(cents) || cents <= 0) return { ok: false, erro: 'Indique o valor a reembolsar.' };

  const { data: id, error } = await client.rpc('registar_reembolso', {
    p_checkout: checkout, p_valor: cents, p_motivo: motivo.trim(),
  });
  if (error || typeof id !== 'string') return { ok: false, erro: error?.code === '22023' ? error.message : 'Não foi possível registar o reembolso.' };

  const { data: k } = await adminClient().from('irs_checkouts')
    .select('provider_order_id, case_id, account_id, cegid_documento, descricao, tipo, amount_cents').eq('id', checkout).single();
  // A fatura escolhida fica ligada ao pagamento: os reembolsos seguintes já a sabem.
  const fatura = origemId.trim() || k?.cegid_documento || null;
  if (origemId.trim() && !k?.cegid_documento) {
    await client.rpc('guardar_cegid_do_pagamento', { p_checkout: checkout, p_documento: origemId.trim() });
  }
  const { data: anteriores } = await adminClient().from('reembolsos')
    .select('amount_cents').eq('checkout_id', checkout).eq('estado', 'feito');
  const parcial = cents + (anteriores || []).reduce((t, r) => t + r.amount_cents, 0) < (k?.amount_cents || 0) || (anteriores || []).length > 0;
  const stripe = await reembolsarNaStripe(k?.provider_order_id || '', cents, id, checkout, motivo.trim());
  if (!stripe.ok) {
    await client.rpc('concluir_reembolso', { p_reembolso: id, p_stripe_id: null, p_stripe_estado: null, p_cegid: null, p_cegid_erro: null, p_falhou: true });
    await registarCegid('reembolso_falhou', `${euros(cents)} · ${stripe.erro}`, k?.account_id || null, k?.case_id || '');
    return { ok: false, erro: `A Stripe recusou o reembolso: ${stripe.erro}` };
  }

  const nota = await notaDeCredito(k?.case_id || '', cents, motivo, fatura, origemRef, k?.descricao || null, parcial);
  await client.rpc('concluir_reembolso', {
    p_reembolso: id, p_stripe_id: stripe.dados.id, p_stripe_estado: stripe.dados.status,
    p_cegid: nota.ok ? nota.id : null, p_cegid_erro: nota.ok ? null : nota.erro, p_falhou: false,
  });
  const cliente = await titularDoProcesso(k?.case_id || '');
  if (cliente?.perfil?.email) {
    await enviarEmail({
      chave: `reembolso:${id}`, para: cliente.perfil.email,
      assunto: `Reembolso de ${euros(cents)} processado`,
      titulo: 'Foi processado um reembolso',
      paragrafos: [`Olá${primeiroNome(cliente.nome) ? `, ${primeiroNome(cliente.nome)}` : ''}.`,
        `Foi processado um reembolso relativo a ${k?.tipo === 'extra' ? `«${k?.descricao || 'pagamento adicional'}»` : 'à preparação do seu IRS'}.`,
        `Motivo: ${motivo.trim()}`,
        'O valor é devolvido pelo mesmo meio de pagamento, normalmente em 5 a 10 dias úteis. A nota de crédito correspondente é emitida em seu nome.'],
      destaque: { rotulo: 'Valor reembolsado', valor: euros(cents) },
      botao: { texto: 'Ver no portal', url: `${PORTAL}/app?separador=pagamento` },
      conta: k?.account_id || null, processo: k?.case_id || null,
    });
  }
  await registarCegid('reembolso',
    `${euros(cents)} · Stripe ${stripe.dados.id} (${stripe.dados.status}) · ${nota.ok ? `nota de crédito em rascunho no Cegid ${nota.id}` : `nota de crédito por criar: ${nota.erro}`} · motivo: ${motivo.trim()}`,
    k?.account_id || null, k?.case_id || '');
  revalidatePath('/irs');
  return {
    ok: true, tom: nota.ok ? 'ok' : 'atencao',
    titulo: `Reembolso de ${euros(cents)} feito`,
    detalhes: [
      `Stripe: devolvido ao cliente (${stripe.dados.id}).`,
      nota.ok
        ? `Cegid: nota de crédito n.º ${nota.id} em rascunho, a ${parcial ? 'corrigir' : 'anular'} a fatura de origem.`
        : `Cegid: a nota de crédito não foi criada — ${nota.erro}`,
      cliente?.perfil?.email ? `Email: aviso enviado para ${cliente.perfil.email}.` : 'Email: o cliente não tem email no perfil.',
    ],
  };
}

async function notaDeCredito(processo: string, cents: number, motivo: string,
  origemId: string | null, origemRef: string, descricao: string | null, parcial = true) {
  const alvo = await titularDoProcesso(processo);
  if (!alvo?.perfil?.nif) return { ok: false as const, erro: 'O cliente não tem NIF no perfil.' };
  if (!origemId && !origemRef.trim()) {
    return { ok: false as const, erro: 'Falta escolher a fatura que a nota de crédito anula ou corrige.' };
  }
  const r = await emitirNotaCredito({
    nif: alvo.perfil.nif, nome: alvo.nome, totalCents: cents, motivo: motivo.trim(),
    descricao: `${parcial ? 'Correção' : 'Anulação'} — ${descricao || 'Preparação do IRS 2026'}`,
    origemId, origemRef: origemRef.trim() || null,
  });
  if (!r.ok) return { ok: false as const, erro: r.nifInvalido ? `O Cegid recusou o NIF ${alvo.perfil.nif}.` : r.erro };
  return { ok: true as const, id: idDoDocumento(r.dados) || 'criada' };
}

/** Criar outra vez a nota de crédito de um reembolso já feito na Stripe. */
export async function repetirNotaCredito(reembolso: string, origemRef = '', origemId = ''): Promise<Resposta> {
  const { client } = await session();
  if (!uuid(reembolso)) return { ok: false, erro: 'Reembolso inválido.' };
  const { data: r } = await adminClient().from('reembolsos')
    .select('amount_cents, motivo, case_id, account_id, cegid_documento, checkout_id, irs_checkouts(cegid_documento, descricao)')
    .eq('id', reembolso).single();
  if (!r) return { ok: false, erro: 'Reembolso inexistente.' };
  if (r.cegid_documento) return { ok: true, aviso: 'A nota de crédito já existe.' };
  const k = (r as { irs_checkouts?: { cegid_documento?: string | null; descricao?: string | null } }).irs_checkouts;
  if (origemId.trim() && !k?.cegid_documento) {
    await client.rpc('guardar_cegid_do_pagamento', { p_checkout: r.checkout_id, p_documento: origemId.trim() });
  }
  const nota = await notaDeCredito(r.case_id, r.amount_cents, r.motivo, origemId.trim() || k?.cegid_documento || null, origemRef, k?.descricao || null);
  if (!nota.ok) {
    await client.rpc('concluir_reembolso', { p_reembolso: reembolso, p_stripe_id: null, p_stripe_estado: null, p_cegid: null, p_cegid_erro: nota.erro, p_falhou: false });
    return { ok: false, erro: nota.erro };
  }
  await client.rpc('concluir_reembolso', { p_reembolso: reembolso, p_stripe_id: null, p_stripe_estado: null, p_cegid: nota.id, p_cegid_erro: null, p_falhou: false });
  await registarCegid('reembolso', `Nota de crédito em rascunho no Cegid ${nota.id} · ${euros(r.amount_cents)}`, r.account_id, r.case_id);
  revalidatePath('/irs');
  return { ok: true, tom: 'ok', titulo: 'Nota de crédito criada', detalhes: [`Cegid: nota de crédito n.º ${nota.id} guardada em rascunho.`] };
}

/** Pagamento adicional combinado com o cliente. Fica uma fatura-recibo em
    rascunho no Cegid e o pedido aparece ao cliente no separador Pagamento. */
export async function pedirPagamentoExtra(processo: string, valor: string, descricao: string): Promise<Resposta> {
  const { client } = await session();
  if (!uuid(processo)) return { ok: false, erro: 'Processo inválido.' };
  const cents = centimos(valor);
  if (!Number.isInteger(cents) || cents < 50) return { ok: false, erro: 'Indique um valor de pelo menos 0,50 €.' };
  const { data: id, error } = await client.rpc('criar_pagamento_extra', {
    p_processo: processo, p_valor: cents, p_descricao: descricao.trim(),
  });
  if (error || typeof id !== 'string') return { ok: false, erro: error?.code === '22023' ? error.message : 'Não foi possível criar o pedido.' };

  const alvo = await titularDoProcesso(processo);
  let cegid = 'Cegid: a fatura-recibo não foi criada — o cliente não tem NIF no perfil.';
  let tudo = false;
  if (alvo?.perfil?.nif) {
    const r = await emitirFaturaRecibo({ nif: alvo.perfil.nif, nome: alvo.nome, descricao: descricao.trim(), totalCents: cents });
    const documento = r.ok ? idDoDocumento(r.dados) : null;
    if (documento) await client.rpc('guardar_cegid_do_pagamento', { p_checkout: id, p_documento: documento });
    tudo = r.ok;
    cegid = r.ok ? `Cegid: fatura-recibo n.º ${documento || '—'} guardada em rascunho.` : `Cegid: a fatura-recibo não foi criada — ${r.erro}`;
  }
  await registarCegid('pagamento_extra', `${euros(cents)} · ${descricao.trim()}`, alvo?.conta || null, processo);
  const avisado = alvo?.perfil?.email ? await enviarEmail({
    chave: `extra:${id}`, para: alvo.perfil.email,
    assunto: `Pagamento adicional pedido — ${euros(cents)}`,
    titulo: 'Foi pedido um pagamento adicional',
    paragrafos: [`Olá${primeiroNome(alvo.nome) ? `, ${primeiroNome(alvo.nome)}` : ''}.`,
      'No âmbito do seu processo de IRS, foi combinado o seguinte pagamento adicional:',
      'Pode pagar de forma segura no separador Pagamento do portal (cartão, MB WAY, Multibanco e outros).'],
    destaque: { rotulo: descricao.trim(), valor: euros(cents) },
    botao: { texto: 'Pagar no portal', url: `${PORTAL}/app?separador=pagamento` },
    conta: alvo.conta, processo,
  }) : false;
  revalidatePath('/irs');
  return {
    ok: true, tom: tudo ? 'ok' : 'atencao',
    titulo: `Pagamento de ${euros(cents)} pedido`,
    detalhes: [`Portal: o pedido aparece ao cliente no separador Pagamento.`, cegid,
      avisado ? `Email: enviado para ${alvo?.perfil?.email}.` : 'Email: não foi enviado (sem email do cliente ou envio indisponível).'],
  };
}

export async function anularPagamentoExtra(checkout: string): Promise<Resposta> {
  const { client } = await session();
  if (!uuid(checkout)) return { ok: false, erro: 'Pagamento inválido.' };
  const { data: sessao, error } = await client.rpc('cancelar_pagamento_extra', { p_checkout: checkout });
  if (error) return { ok: false, erro: error.code === '22023' ? error.message : 'Não foi possível anular.' };
  await expirarSessao(typeof sessao === 'string' ? sessao : null);
  revalidatePath('/irs');
  return { ok: true, tom: 'atencao', titulo: 'Pedido anulado', detalhes: ['Portal: o pedido deixou de aparecer ao cliente.', 'Cegid: se havia fatura-recibo em rascunho, apague-a lá.'] };
}

/** As faturas do cliente no Cegid, para a nota de crédito escolher a que anula
    ou corrige. Vem já sugerida a que está ligada ao pagamento, ou a de valor
    igual mais recente. */
export async function faturasParaReembolso(checkout: string): Promise<
  { ok: true; faturas: FaturaCegid[]; sugerida: string | null } | { ok: false; erro: string }
> {
  await session();
  if (!uuid(checkout)) return { ok: false, erro: 'Pagamento inválido.' };
  const { data: k } = await adminClient().from('irs_checkouts')
    .select('case_id, amount_cents, cegid_documento').eq('id', checkout).single();
  if (!k) return { ok: false, erro: 'Pagamento inexistente.' };
  const alvo = await titularDoProcesso(k.case_id);
  if (!alvo?.perfil?.nif) return { ok: false, erro: 'O cliente não tem NIF no perfil.' };
  const r = await faturasDoCliente(alvo.perfil.nif);
  if (!r.ok) return { ok: false, erro: `Não foi possível ler as faturas no Cegid: ${r.erro}` };
  const sugerida = (k.cegid_documento && r.dados.some((f) => f.id === k.cegid_documento) ? k.cegid_documento : null)
    || r.dados.find((f) => f.totalCents === k.amount_cents)?.id
    || r.dados[0]?.id || null;
  return { ok: true, faturas: r.dados, sugerida };
}
