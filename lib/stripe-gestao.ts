import 'server-only';

/* A Stripe vista da gestão: devolver dinheiro e fechar sessões. Sem SDK, como
   no portal: são dois pedidos HTTP. A chave é a mesma conta do portal. */

const chave = () => process.env.STRIPE_SECRET_KEY || '';

async function pedir<T>(caminho: string, corpo?: Record<string, string>, idempotencia?: string) {
  const k = chave();
  if (!/^sk_(test|live)_/.test(k)) return { ok: false as const, erro: 'A Stripe não está configurada na gestão.' };
  const r = await fetch(`https://api.stripe.com/v1${caminho}`, {
    method: corpo ? 'POST' : 'GET',
    headers: {
      Authorization: `Bearer ${k}`,
      ...(corpo ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}),
      ...(idempotencia ? { 'Idempotency-Key': idempotencia } : {}),
    },
    body: corpo ? new URLSearchParams(corpo).toString() : undefined,
    cache: 'no-store',
  });
  const dados = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = (dados as { error?: { message?: string } }).error?.message;
    return { ok: false as const, erro: msg || `A Stripe recusou o pedido (${r.status}).` };
  }
  return { ok: true as const, dados: dados as T };
}

/** Devolve parte ou a totalidade de um pagamento feito por uma sessão do
    Checkout. A chave de idempotência é o id do reembolso: repetir o pedido
    nunca devolve duas vezes. */
export async function reembolsarNaStripe(sessao: string, cents: number, reembolso: string) {
  if (!/^cs_[A-Za-z0-9_]+$/.test(sessao)) return { ok: false as const, erro: 'Sessão da Stripe inválida.' };
  const lida = await pedir<{ payment_intent?: string | { id: string } }>(`/checkout/sessions/${sessao}`);
  if (!lida.ok) return lida;
  const pi = lida.dados.payment_intent;
  const intencao = typeof pi === 'string' ? pi : pi?.id;
  if (!intencao) return { ok: false as const, erro: 'O pagamento não tem intenção de pagamento na Stripe.' };
  return pedir<{ id: string; status: string }>('/refunds', {
    payment_intent: intencao,
    amount: String(cents),
    reason: 'requested_by_customer',
    'metadata[reembolso]': reembolso,
  }, `reembolso-${reembolso}`);
}

/** Fecha uma sessão de Checkout ainda aberta (pagamento adicional anulado). */
export async function expirarSessao(sessao: string | null) {
  if (!sessao || !/^cs_[A-Za-z0-9_]+$/.test(sessao)) return;
  await pedir(`/checkout/sessions/${sessao}/expire`, {});
}
