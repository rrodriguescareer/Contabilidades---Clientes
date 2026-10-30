'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import type { SupabaseClient } from '@supabase/supabase-js';
import { ownerSession } from './auth';
import { enviarEmail } from './email';
import { lerFicha } from './empresa-ficha';
import { tipoReal } from './empresa-tipos-ficheiro';
import { uuid } from './data';

/* A ficha, as definições, os alertas, o pessoal, os recibos e os impostos de
   cada empresa do portal, do lado do contabilista. Cada função da base volta
   a verificar o contabilista. */

const texto = (form: FormData, nome: string) => String(form.get(nome) || '').trim();
const PORTAL = (process.env.NEXT_PUBLIC_EMPRESAS_URL || 'https://portal.rr-contabilidade.com').replace(/\/$/, '');
const BUCKET = 'empresas-ficheiros';
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const nomeMes = (mes: string) => { const [a, m] = mes.split('-').map(Number); return `${MESES[m - 1]} de ${a}`; };
const euros = (v: number) => new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR', useGrouping: 'always' } as Intl.NumberFormatOptions).format(v);
const data = (iso: string) => iso.split('-').reverse().join('/');

function voltar(empresa: string, aba: string, chave: 'erro' | 'mensagem', mensagem: string, extra = ''): never {
  revalidatePath(`/empresas/${empresa}`);
  revalidatePath('/empresas');
  redirect(`/empresas/${empresa}?aba=${aba}&${chave}=${encodeURIComponent(mensagem)}${extra}`);
}

async function empresaDoForm(form: FormData) {
  const sessao = await ownerSession();
  const id = texto(form, 'empresa');
  if (!uuid(id)) redirect('/empresas?erro=Empresa%20inv%C3%A1lida.');
  return { ...sessao, id };
}

/** Avisa por email as pessoas com acesso ativo à empresa. Nunca falha. */
async function avisarClientes(client: SupabaseClient, empresa: string, chave: string, assunto: string, titulo: string, paragrafos: string[], caminho: string) {
  const { data: e } = await client.from('companies').select('name,company_users(active,profile:profiles(email))').eq('id', empresa).maybeSingle();
  type Ligacao = { active: boolean; profile: { email: string } | null };
  for (const l of ((e?.company_users ?? []) as unknown as Ligacao[]).filter((x) => x.active && x.profile?.email)) {
    await enviarEmail({
      chave: `${chave}:${l.profile!.email}`, para: l.profile!.email,
      assunto: `${assunto} — ${e?.name ?? 'a sua empresa'}`, titulo, paragrafos,
      botao: { texto: 'Abrir no portal', url: `${PORTAL}/app/${empresa}${caminho}` },
    });
  }
}

/** Um ficheiro do contabilista (recibos ou guia): sem conversão, até 10 MB. */
async function carregar(client: SupabaseClient, empresa: string, contexto: 'recibos' | 'guia', ref: string, ficheiro: File) {
  if (ficheiro.size > 10 * 1024 * 1024) return { erro: `${ficheiro.name}: tem mais de 10 MB.` };
  const bytes = new Uint8Array(await ficheiro.arrayBuffer());
  const mime = tipoReal(bytes);
  if (!mime) return { erro: `${ficheiro.name}: só PDF, JPEG, PNG ou WebP.` };
  const { data: p, error } = await client.rpc('preparar_ficheiro_empresa', {
    empresa, p_contexto: contexto, p_ref: ref, p_nome: ficheiro.name.slice(0, 200) || 'documento', p_mime: mime, p_tamanho: bytes.byteLength,
  });
  if (error || !p?.caminho) return { erro: 'Não foi possível registar o ficheiro.' };
  const { error: semFicheiro } = await client.storage.from(BUCKET).upload(p.caminho, bytes, { contentType: mime, upsert: false });
  if (semFicheiro) { await client.rpc('apagar_ficheiro_empresa', { ficheiro: p.id }); return { erro: 'O envio do ficheiro falhou.' }; }
  const { error: semFim } = await client.rpc('concluir_ficheiro_empresa', { ficheiro: p.id });
  if (semFim) return { erro: 'O ficheiro não ficou concluído.' };
  return { ok: true as const, id: p.id as string };
}

async function apagarFicheiros(client: SupabaseClient, ids: { id: string; caminho: string }[]) {
  if (!ids.length) return;
  await client.storage.from(BUCKET).remove(ids.map((f) => f.caminho));
  for (const f of ids) await client.rpc('apagar_ficheiro_empresa', { ficheiro: f.id });
}

/* ------------------------------------------------------------ ficha */

export async function guardarFichaGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const lido = lerFicha(form);
  if ('erro' in lido) voltar(id, 'ficha', 'erro', lido.erro!);
  const { data: n, error } = await client.rpc('guardar_ficha_empresa', { empresa: id, dados: lido.dados });
  if (error) voltar(id, 'ficha', 'erro', /NIF/.test(error.message) ? (error.message.includes('Já existe') ? 'Já existe outra empresa com este NIF.' : 'NIF inválido.') : 'Não foi possível guardar a ficha.');
  voltar(id, 'ficha', 'mensagem', n ? `Ficha guardada: ${n} campo(s) alterado(s).` : 'Nada mudou.');
}

export async function enviarLogotipoGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const f = form.get('logotipo');
  if (!(f instanceof File) || !f.size) voltar(id, 'ficha', 'erro', 'Escolha a imagem.');
  if (f.size > 500 * 1024) voltar(id, 'ficha', 'erro', 'O logótipo tem de ter menos de 500 KB. No portal, o cliente pode enviar imagens maiores: são otimizadas.');
  const bytes = new Uint8Array(await f.arrayBuffer());
  const mime = tipoReal(bytes);
  if (mime !== 'image/png' && mime !== 'image/webp') voltar(id, 'ficha', 'erro', 'Aqui só PNG ou WebP.');
  const caminho = `${id}/logotipo-${Date.now()}.${mime === 'image/png' ? 'png' : 'webp'}`;
  const { error } = await client.storage.from('empresas-logotipos').upload(caminho, bytes, { contentType: mime, upsert: false });
  if (error) voltar(id, 'ficha', 'erro', 'Não foi possível guardar a imagem.');
  const { data: anterior, error: semRegisto } = await client.rpc('definir_logotipo_empresa', { empresa: id, caminho });
  if (semRegisto) voltar(id, 'ficha', 'erro', 'Não foi possível guardar o logótipo.');
  if (anterior) await client.storage.from('empresas-logotipos').remove([anterior]);
  voltar(id, 'ficha', 'mensagem', 'Logótipo guardado.');
}

/* ------------------------------------------------------------ definições */

export async function definirInicio(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const mes = texto(form, 'inicio');
  if (mes && !/^\d{4}-\d{2}$/.test(mes)) voltar(id, 'resumo', 'erro', 'Mês inválido.');
  const { error } = await client.rpc('definir_inicio_empresa', { empresa: id, p_inicio: mes ? `${mes}-01` : null });
  if (error) voltar(id, 'resumo', 'erro', 'Não foi possível guardar o início.');
  voltar(id, 'resumo', 'mensagem', mes ? `Acompanhamento a partir de ${nomeMes(mes)}: os meses anteriores deixam de aparecer no portal.` : 'Início retirado.');
}

export async function definirMes(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const mes = texto(form, 'mes');
  const estado = texto(form, 'estado'); // aberto | bloqueado | fechado
  if (!/^\d{4}-\d{2}$/.test(mes) || !['aberto', 'bloqueado', 'fechado'].includes(estado)) voltar(id, 'documentos', 'erro', 'Pedido inválido.');
  const { error } = await client.rpc('definir_mes_empresa', { empresa: id, p_mes: `${mes}-01`, p_bloqueado: estado === 'bloqueado', p_fechado: estado === 'fechado' });
  if (error) voltar(id, 'documentos', 'erro', 'Não foi possível alterar o mês.', `&mes=${mes}`);
  voltar(id, 'documentos', 'mensagem',
    estado === 'fechado' ? `${nomeMes(mes)} fechado: informação completa.` : estado === 'bloqueado' ? `Envio bloqueado em ${nomeMes(mes)}.` : `${nomeMes(mes)} aberto para envio.`, `&mes=${mes}`);
}

/* ------------------------------------------------------------ alertas */

export async function criarAlerta(form: FormData) {
  const { client, user, id } = await empresaDoForm(form);
  const titulo = texto(form, 'titulo').slice(0, 200);
  const nivel = texto(form, 'nivel');
  const expira = texto(form, 'expira');
  if (!titulo || !['info', 'aviso', 'urgente'].includes(nivel)) voltar(id, 'alertas', 'erro', 'Indique o título e o nível do alerta.');
  if (expira && !/^\d{4}-\d{2}-\d{2}$/.test(expira)) voltar(id, 'alertas', 'erro', 'Data inválida.');
  const todas = form.get('todas') === 'on';
  const { error } = await client.from('empresa_alertas').insert({
    company_id: todas ? null : id, titulo, corpo: texto(form, 'corpo').slice(0, 2000) || null, nivel, expira_em: expira || null, criado_por: user.id,
  });
  if (error) voltar(id, 'alertas', 'erro', 'Não foi possível criar o alerta.');
  if (form.get('email') === 'on' && !todas) {
    await avisarClientes(client, id, `empresa-alerta:${Date.now()}`, titulo, titulo, [texto(form, 'corpo') || 'Tem um alerta novo no portal.'], '');
  }
  voltar(id, 'alertas', 'mensagem', todas ? 'Alerta publicado em todas as empresas.' : 'Alerta publicado no portal da empresa.');
}

export async function apagarAlerta(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const alerta = texto(form, 'alerta');
  if (!uuid(alerta)) voltar(id, 'alertas', 'erro', 'Alerta inválido.');
  await client.from('empresa_alertas').delete().eq('id', alerta);
  voltar(id, 'alertas', 'mensagem', 'Alerta apagado.');
}

/* ------------------------------------------------------------ pessoal */

export async function tratarPessoalGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const estado = texto(form, 'estado');
  const resposta = texto(form, 'resposta');
  const { error } = await client.rpc('tratar_pessoal', { pedido: texto(form, 'pedido'), p_estado: estado, p_resposta: resposta || null });
  if (error) voltar(id, 'pessoal', 'erro', 'Não foi possível atualizar o pedido.');
  if (estado === 'tratado' || estado === 'devolvido') {
    await avisarClientes(client, id, `empresa-pessoal-${estado}:${texto(form, 'pedido')}`,
      estado === 'tratado' ? 'Comunicação de pessoal tratada' : 'Comunicação de pessoal devolvida',
      estado === 'tratado' ? 'A sua comunicação de pessoal foi tratada.' : 'A sua comunicação de pessoal precisa de correção.',
      [resposta || (estado === 'tratado' ? 'O contabilista tratou o pedido.' : 'Veja no portal o que falta.')], '/pessoal');
  }
  voltar(id, 'pessoal', 'mensagem', 'Pedido atualizado.');
}

export async function publicarRecibos(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const mes = texto(form, 'mes');
  const f = form.get('ficheiro');
  if (!/^\d{4}-\d{2}$/.test(mes) || !(f instanceof File) || !f.size) voltar(id, 'pessoal', 'erro', 'Escolha o mês e o PDF dos recibos.');
  const { data: ref, error } = await client.rpc('preparar_recibos_mes', { empresa: id, p_mes: `${mes}-01` });
  if (error || !ref) voltar(id, 'pessoal', 'erro', 'Não foi possível preparar os recibos.');
  const { data: antigos } = await client.from('empresa_ficheiros').select('id,caminho').eq('ref_id', ref).eq('contexto', 'recibos');
  const r = await carregar(client, id, 'recibos', ref, f);
  if ('erro' in r) voltar(id, 'pessoal', 'erro', r.erro!);
  // Um ficheiro por mês: o novo substitui o anterior.
  await apagarFicheiros(client, (antigos ?? []).filter((x) => x.id !== r.id));
  await avisarClientes(client, id, `empresa-recibos:${ref}:${r.id}`, `Recibos de vencimento de ${nomeMes(mes)}`,
    `Os recibos de ${nomeMes(mes)} estão disponíveis.`, ['Pode descarregá-los no portal, na secção Pessoal.'], '/pessoal');
  voltar(id, 'pessoal', 'mensagem', `Recibos de ${nomeMes(mes)} publicados e cliente avisado.`);
}

/* ------------------------------------------------------------ impostos */

export async function guardarImpostoGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const imposto = texto(form, 'imposto') || null;
  const tipo = texto(form, 'tipo');
  const periodo = texto(form, 'periodo');
  const valorTexto = texto(form, 'valor').replace(/\s/g, '').replace(',', '.');
  const prazo = texto(form, 'prazo');
  const valor = valorTexto ? Number(valorTexto) : null;
  if (!['IRC', 'IVA', 'IRS', 'SS', 'OUTROS'].includes(tipo) || !periodo || periodo.length > 20) voltar(id, 'impostos', 'erro', 'Indique o tipo e o período (ex.: 2026-09, 2026T3, 2025).');
  if (valor != null && (!Number.isFinite(valor) || valor < 0)) voltar(id, 'impostos', 'erro', 'Valor inválido.');
  if (prazo && !/^\d{4}-\d{2}-\d{2}$/.test(prazo)) voltar(id, 'impostos', 'erro', 'Prazo inválido.');
  const { data: novo, error } = await client.rpc('guardar_imposto', {
    p_id: imposto, empresa: id, p_tipo: tipo, p_periodo: periodo, p_descricao: texto(form, 'descricao') || null,
    p_referencia: texto(form, 'referencia') || null, p_valor: valor, p_prazo: prazo || null,
  });
  if (error || !novo) voltar(id, 'impostos', 'erro', 'Não foi possível guardar o imposto.');
  const f = form.get('guia');
  let comGuia = false;
  if (f instanceof File && f.size) {
    const r = await carregar(client, id, 'guia', novo, f);
    if ('erro' in r) voltar(id, 'impostos', 'erro', `Imposto guardado, mas a guia falhou: ${r.erro}`);
    comGuia = true;
  }
  if (!imposto || comGuia) {
    await avisarClientes(client, id, `empresa-imposto:${novo}:${comGuia ? 'guia' : 'novo'}`,
      `Pagamento de ${tipo} ${periodo}`, `Tem um pagamento de ${tipo} (${periodo}) para fazer.`,
      [
        valor != null ? `Valor: ${euros(valor)}.` : 'O valor está no portal.',
        prazo ? `Prazo de pagamento: ${data(prazo)}.` : 'Veja o prazo no portal.',
        texto(form, 'referencia') ? `Referência: ${texto(form, 'referencia')}.` : (comGuia ? 'A guia está no portal.' : ''),
        'Depois de pagar, marque como pago no portal e junte o comprovativo.',
      ].filter(Boolean), '/impostos');
  }
  voltar(id, 'impostos', 'mensagem', imposto ? 'Imposto atualizado.' : 'Imposto publicado e cliente avisado por email.');
}

export async function apagarImpostoGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const imposto = texto(form, 'imposto');
  if (!uuid(imposto)) voltar(id, 'impostos', 'erro', 'Imposto inválido.');
  const { data: ficheiros } = await client.from('empresa_ficheiros').select('id,caminho').eq('ref_id', imposto);
  if (ficheiros?.length) await client.storage.from(BUCKET).remove(ficheiros.map((f) => f.caminho));
  const { error } = await client.rpc('apagar_imposto', { p_id: imposto });
  if (error) voltar(id, 'impostos', 'erro', 'Não foi possível apagar.');
  voltar(id, 'impostos', 'mensagem', 'Imposto apagado.');
}

export async function marcarImpostoGestao(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const { error } = await client.rpc('marcar_imposto_pago', { p_id: texto(form, 'imposto'), pago: texto(form, 'pago') === 'true' });
  if (error) voltar(id, 'impostos', 'erro', 'Não foi possível atualizar.');
  voltar(id, 'impostos', 'mensagem', 'Estado do pagamento atualizado.');
}

export async function renovarCegid(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const { error } = await client.rpc('renovar_cegid_empresa', { empresa: id });
  if (error) voltar(id, 'resumo', 'erro', 'Não foi possível renovar.');
  voltar(id, 'resumo', 'mensagem', 'Os dados do Cegid voltam a ser lidos no próximo acesso ao portal.');
}
