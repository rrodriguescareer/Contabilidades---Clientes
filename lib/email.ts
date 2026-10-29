import 'server-only';
import { adminClient } from './admin-client';

/* Os emails das plataformas, por Resend.
 *
 * Cada email tem uma chave única ("pago:<pagamento>", "reembolso:<id>"…),
 * gravada antes de enviar: se o mesmo aviso for pedido duas vezes — o webhook
 * da Stripe e a página de regresso confirmam o mesmo pagamento —, só o
 * primeiro sai. O envio nunca faz falhar a operação que o pediu: um erro fica
 * na tabela e no log. Cada email enviado ao cliente entra também no registo
 * de atividade, que é a prova do que foi comunicado e quando. */

const REMETENTE = 'Rúben Meirinho Rodrigues <irs@rr-contabilidade.com>';
const RESPOSTA = 'contabilidade.rubenrodrigues@gmail.com';
export const EMAIL_GABINETE = process.env.EMAIL_GABINETE || RESPOSTA;
export const PORTAL = (process.env.NEXT_PUBLIC_IRS_URL || 'https://irs.rr-contabilidade.com').replace(/\/$/, '');
export const GESTAO = (process.env.NEXT_PUBLIC_GESTAO_URL || 'https://gestao.rr-contabilidade.com').replace(/\/$/, '');

export type Email = {
  chave: string;
  para: string;
  assunto: string;
  titulo: string;
  paragrafos: string[];
  destaque?: { rotulo: string; valor: string } | null;
  botao?: { texto: string; url: string } | null;
  conta?: string | null;
  processo?: string | null;
  utilizador?: string | null;
  /** Email para o gabinete: não entra no registo de atividade do cliente. */
  interno?: boolean;
};

const esc = (t: string) =>
  t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** O HTML do email (também usado para o pré-visualizar). */
export function html(e: Email) {
  const p = e.paragrafos.map((t) =>
    `<p style="margin:0 0 14px;font-size:15px;line-height:1.6;color:#33475b">${esc(t)}</p>`).join('');
  const destaque = e.destaque ? `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:6px 0 20px;border-collapse:separate">
      <tr><td style="background:#eef3fd;border-radius:12px;padding:16px 18px">
        <div style="font-size:13px;color:#5b6b82">${esc(e.destaque.rotulo)}</div>
        <div style="font-size:26px;font-weight:700;color:#0a2344;letter-spacing:-.5px;margin-top:4px">${esc(e.destaque.valor)}</div>
      </td></tr>
    </table>` : '';
  const botao = e.botao ? `
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 6px">
      <tr><td style="background:#2867f8;border-radius:999px">
        <a href="${esc(e.botao.url)}" style="display:inline-block;padding:13px 26px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none">${esc(e.botao.texto)}</a>
      </td></tr>
    </table>` : '';
  return `<!doctype html><html lang="pt"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(e.assunto)}</title></head>
<body style="margin:0;padding:0;background:#f3f7fd;font-family:Inter,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f7fd;padding:28px 12px">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #e4ebf6">
        <tr><td style="background:#0a2344;padding:22px 28px">
          <img src="${PORTAL}/email-rr.png" alt="RR." height="36" style="display:block;height:36px;border:0">
        </td></tr>
        <tr><td style="padding:30px 28px 24px">
          <h1 style="margin:0 0 16px;font-size:22px;line-height:1.3;color:#0a2344;letter-spacing:-.3px">${esc(e.titulo)}</h1>
          ${p}${destaque}${botao}
        </td></tr>
        <tr><td style="padding:18px 28px 24px;border-top:1px solid #e4ebf6">
          <p style="margin:0 0 6px;font-size:13px;color:#33475b"><strong>Rúben Meirinho Rodrigues</strong> · Contabilista Certificado n.º 145854</p>
          <p style="margin:0;font-size:12px;line-height:1.5;color:#7a8aa0">Rua Augusto Simões 845, 4470-147 Maia · ${RESPOSTA}<br>Mensagem automática do portal IRS. Pode responder a este email ou usar as mensagens no portal.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
}

function texto(e: Email) {
  return [e.titulo, '', ...e.paragrafos,
    ...(e.destaque ? ['', `${e.destaque.rotulo}: ${e.destaque.valor}`] : []),
    ...(e.botao ? ['', `${e.botao.texto}: ${e.botao.url}`] : []),
    '', '—', 'Rúben Meirinho Rodrigues · Contabilista Certificado n.º 145854', RESPOSTA].join('\n');
}

/** Envia um email uma vez só por chave. Devolve se saiu agora. */
export async function enviarEmail(e: Email): Promise<boolean> {
  const chave = process.env.RESEND_API_KEY || '';
  if (!/^re_/.test(chave) || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e.para)) return false;
  const admin = adminClient();
  try {
    const { data: novo } = await admin.from('emails')
      .upsert({ chave: e.chave.slice(0, 200), para: e.para, assunto: e.assunto.slice(0, 250),
                account_id: e.conta ?? null, case_id: e.processo ?? null },
              { onConflict: 'chave', ignoreDuplicates: true })
      .select('id');
    const id = novo?.[0]?.id;
    if (!id) return false; // já tinha sido enviado

    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json', 'Idempotency-Key': `rr-${id}` },
      body: JSON.stringify({ from: REMETENTE, to: [e.para], reply_to: RESPOSTA, subject: e.assunto, html: html(e), text: texto(e) }),
      cache: 'no-store',
    });
    const corpo = await r.json().catch(() => ({})) as { id?: string; message?: string };
    if (!r.ok) {
      await admin.from('emails').update({ estado: 'falhou', erro: String(corpo.message || r.status).slice(0, 500) }).eq('id', id);
      console.error(JSON.stringify({ event: 'rr_email_falhou', chave: e.chave, erro: corpo.message || r.status }));
      return false;
    }
    await admin.from('emails').update({ estado: 'enviado', resend_id: corpo.id || null, enviado_em: new Date().toISOString() }).eq('id', id);
    if (!e.interno) {
      await admin.from('registo_atividade').insert({
        user_id: e.utilizador ?? null, account_id: e.conta ?? null, case_id: e.processo ?? null,
        tipo: 'email', detalhe: `«${e.assunto}» para ${e.para}`.slice(0, 2000),
      });
    }
    return true;
  } catch (falha) {
    console.error(JSON.stringify({ event: 'rr_email_falhou', chave: e.chave, erro: String((falha as Error)?.message || falha) }));
    return false;
  }
}

export const primeiroNome = (nome?: string | null) => (nome || '').trim().split(/\s+/)[0] || '';
export const eurosTexto = (c: number) => (c / 100).toFixed(2).replace('.', ',') + ' €';
