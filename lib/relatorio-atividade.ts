import 'server-only';
import { session } from './auth';

/* O relatório de atividade de um processo: a prova a enviar ao Stripe numa
   contestação de pagamento. A linha do tempo vem da base numa consulta só; o
   detalhe do pagamento (cartão, 3-D Secure, identificadores) vem do Stripe. */

export type Evento = { em: string; origem: string; evento: string; detalhe: string | null };
export type Relatorio = {
  cliente: Record<string, string | null> | null;
  processo: Record<string, unknown> | null;
  pagamentos: {
    id: string; estado: string; total: number; desconto: number | null; criado: string;
    pago_em: string | null; sessao: string | null;
  }[];
  eventos: Evento[];
};

export type DetalheStripe = {
  sessao: string;
  intencao: string | null;
  cobranca: string | null;
  criado: string | null;
  metodo: string | null;
  cartao: string | null;
  pais: string | null;
  tresDS: string | null;
  cvc: string | null;
  rede: string | null;
  risco: string | null;
  email: string | null;
  nome: string | null;
};

const LISBOA = new Intl.DateTimeFormat('pt-PT', {
  timeZone: 'Europe/Lisbon', day: '2-digit', month: '2-digit', year: 'numeric',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
});
/** dd/mm/aaaa hh:mm:ss, sempre na hora de Lisboa (o servidor corre em UTC). */
export const dataHora = (iso: string | null | undefined) =>
  iso ? LISBOA.format(new Date(iso)).replace(',', '') : '—';

export async function lerRelatorio(processo: string) {
  const { client } = await session();
  const { data, error } = await client.rpc('relatorio_de_atividade', { processo });
  if (error || !data) return null;
  return data as Relatorio;
}

/** O que o Stripe sabe de um pagamento. Sem chave ou sem resposta, fica de fora. */
export async function lerStripe(sessao: string): Promise<DetalheStripe | null> {
  const chave = process.env.STRIPE_SECRET_KEY || '';
  if (!/^sk_(test|live)_/.test(chave) || !/^cs_[A-Za-z0-9_]+$/.test(sessao)) return null;
  try {
    const r = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${sessao}?expand[]=payment_intent.latest_charge`,
      { headers: { Authorization: `Bearer ${chave}` }, cache: 'no-store' },
    );
    if (!r.ok) return null;
    const s = await r.json();
    const pi = typeof s.payment_intent === 'object' ? s.payment_intent : null;
    const ch = pi && typeof pi.latest_charge === 'object' ? pi.latest_charge : null;
    const pm = ch?.payment_method_details || {};
    const card = pm.card || null;
    return {
      sessao,
      intencao: pi?.id || (typeof s.payment_intent === 'string' ? s.payment_intent : null),
      cobranca: ch?.id || null,
      criado: ch?.created ? new Date(ch.created * 1000).toISOString() : null,
      metodo: pm.type || null,
      cartao: card ? `${String(card.brand || '').toUpperCase()} •••• ${card.last4}${card.exp_month ? ` (validade ${String(card.exp_month).padStart(2, '0')}/${card.exp_year})` : ''}` : null,
      pais: card?.country || null,
      tresDS: card?.three_d_secure?.result || card?.three_d_secure?.authentication_flow || null,
      cvc: card?.checks?.cvc_check || null,
      rede: ch?.outcome?.network_status || null,
      risco: ch?.outcome?.risk_level || null,
      email: s.customer_details?.email || ch?.billing_details?.email || null,
      nome: s.customer_details?.name || ch?.billing_details?.name || null,
    };
  } catch {
    return null;
  }
}
