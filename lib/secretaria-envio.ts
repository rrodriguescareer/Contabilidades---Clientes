import 'server-only';
import { createHash, randomBytes } from 'node:crypto';
import { adminClient } from './admin-client';
import { EMAIL_GABINETE, GESTAO, enviarEmail } from './email';
import { comporEmail, dataPt, type PendenciaAberta } from './secretaria';

/* O envio de cada email da Secretária. Corre com a chave do servidor: tanto
 * pode ser o contabilista a aprovar como o relógio de hora a hora.
 *
 * A base reserva o envio (nunca sai duas vezes). Cada email leva uma ligação
 * própria, gerada aqui: guarda-se só o hash, e a ligação morre com o processo. */

const ENTREGA = (process.env.NEXT_PUBLIC_EMPRESAS_URL || 'https://portal.rr-contabilidade.com').replace(/\/$/, '');

type Reserva = {
  id: string; tipo: string; assunto: string; corpo: string; tentativas: number;
  empresa_id: string; empresa: string; nif: string; dia_limite: string; em_curso: boolean;
  contactos: { nome: string; email: string; principal: boolean; em_cc: boolean }[];
  pendencias: PendenciaAberta[];
};

export async function enviarPedido(id: string): Promise<{ ok: boolean; erro?: string }> {
  const admin = adminClient();
  const { data, error } = await admin.rpc('secretaria_reservar_envio', { envio: id });
  if (error) return { ok: false, erro: 'Não foi possível reservar o envio.' };
  if (!data) return { ok: false, erro: 'Este email já está a ser enviado.' };
  const r = data as Reserva;

  const fim = (ok: boolean, para: string | null, cc: string[], hash: string | null, erro: string | null) =>
    admin.rpc('secretaria_envio_resultado', { envio: id, ok, p_para: para, p_cc: cc, p_hash: hash, p_erro: erro });

  const principal = r.contactos.find((c) => c.principal);
  if (!principal) { await fim(false, null, [], null, 'Sem contacto principal contactável.'); return { ok: false, erro: 'Falta um contacto principal contactável.' }; }
  if (!r.pendencias.length) { await fim(false, principal.email, [], null, 'Já não há documentos em falta.'); return { ok: false, erro: 'Já não há documentos em falta.' }; }

  const token = randomBytes(32).toString('base64url');
  const hash = createHash('sha256').update(token).digest('hex');
  const cc = r.contactos.filter((c) => c.em_cc && !c.principal).map((c) => c.email);
  const email = comporEmail({ tipo: r.tipo, assunto: r.assunto, corpo: r.corpo, empresa: r.empresa, contacto: principal.nome, pendencias: r.pendencias, diaLimite: r.dia_limite });

  const ok = await enviarEmail({
    chave: `secretaria:${id}:${r.tentativas}`, para: principal.email, cc, interno: true,
    assunto: email.assunto, titulo: email.titulo, paragrafos: email.paragrafos, rodape: email.rodape,
    botao: { texto: 'Entregar os documentos', url: `${ENTREGA}/entregar/${token}` },
  });
  await fim(ok, principal.email, cc, ok ? hash : null, ok ? null : 'O serviço de email recusou o envio.');
  return ok ? { ok } : { ok, erro: 'O serviço de email recusou o envio.' };
}

/** O resumo da semana, à segunda de manhã, se houver algo a dizer. */
export async function enviarResumoSemanal(hoje: string) {
  const admin = adminClient();
  const [{ data: definicoes }, { data: painel }] = await Promise.all([
    admin.from('secretaria_definicoes').select('resumo_semanal').maybeSingle(),
    admin.rpc('secretaria_painel'),
  ]);
  if (!definicoes?.resumo_semanal || !painel) return false;
  const p = painel as Record<string, number>;
  if (!p.em_falta && !p.por_aprovar && !p.processos && !p.por_identificar) return false;
  return enviarEmail({
    chave: `secretaria-resumo:${hoje}`, para: EMAIL_GABINETE, interno: true,
    assunto: `Resumo da semana: ${p.em_falta} documentos em falta`,
    titulo: 'O ponto da situação, ao começar a semana.',
    paragrafos: [
      `Na semana de ${dataPt(hoje)}, há ${p.processos} processos em curso e ${p.em_falta} documentos em falta.`,
      `Por aprovar: ${p.por_aprovar}. Por identificar: ${p.por_identificar}. Clientes com pendências e sem processo: ${p.sem_processo}.`,
      `Recebidos nos últimos 30 dias: ${p.recebidos}.`,
    ],
    botao: { texto: 'Abrir a Secretária', url: `${GESTAO}/secretaria` },
    rodape: 'Resumo semanal da Secretária. Pode desligá-lo nas definições.',
  });
}
