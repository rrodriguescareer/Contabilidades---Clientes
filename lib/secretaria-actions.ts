'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import type { SupabaseClient } from '@supabase/supabase-js';
import { adminClient } from './admin-client';
import { ownerSession, session } from './auth';
import { uuid } from './data';
import { enviarPedido } from './secretaria-envio';
import { TIPOS, lerValor, type Cadencia, type LinhaImportada } from './secretaria';

/* O que o contabilista faz na Secretária. Cada função da base volta a
   verificar quem chama; aqui valida-se a forma e devolve-se à página. */

const texto = (f: FormData, n: string) => String(f.get(n) || '').trim();
const marcado = (f: FormData, n: string) => f.get(n) === 'on';

function volta(f: FormData, chave: 'mensagem' | 'erro', msg: string, destino?: string): never {
  const pedido = destino || texto(f, 'voltar');
  const caminho = /^\/secretaria(\/|\?|$)/.test(pedido) ? pedido : '/secretaria';
  revalidatePath('/', 'layout');
  redirect(`${caminho}${caminho.includes('?') ? '&' : '?'}${chave}=${encodeURIComponent(msg)}&t=${Date.now()}`);
}

function lerCadencia(f: FormData): Cadencia {
  const modo = texto(f, 'modo');
  const hora = Math.min(23, Math.max(0, Number(texto(f, 'hora')) || 9));
  if (modo === 'semana') {
    const dias: Record<string, number> = {};
    for (const d of ['1', '2', '3', '4', '5']) {
      const v = texto(f, `dia_${d}`);
      if (v !== '' && Number.isInteger(Number(v)) && Number(v) >= 0 && Number(v) <= 23) dias[d] = Number(v);
    }
    return { modo: 'semana', dias };
  }
  return { modo: modo === 'uteis' ? 'uteis' : 'corridos', intervalo: Math.min(60, Math.max(1, Number(texto(f, 'intervalo')) || 7)), hora };
}

/* ------------------------------------------------------------ pendências */

export async function guardarPendencia(f: FormData) {
  const { client, user } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const tipo = texto(f, 'tipo');
  const descricao = texto(f, 'descricao').slice(0, 200);
  const data = texto(f, 'data');
  if (!uuid(empresa) || !TIPOS[tipo] || !descricao) volta(f, 'erro', 'Indique o tipo e a descrição do documento.');
  if (data && !/^\d{4}-\d{2}-\d{2}$/.test(data)) volta(f, 'erro', 'A data não é válida.');
  // Com data, o período é o mês da data; o campo do período só serve sem ela.
  const periodo = data ? data.slice(0, 7) : texto(f, 'periodo');
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(periodo)) volta(f, 'erro', 'Indique a data do documento ou o período a que respeita.');
  const valorTexto = texto(f, 'valor');
  const valor = valorTexto ? lerValor(valorTexto) : null;
  if (valorTexto && valor === null) volta(f, 'erro', 'O valor não é válido.');
  const { error } = await client.from('secretaria_pendencias').insert({
    company_id: empresa, periodo: `${periodo}-01`, tipo, descricao, numero: texto(f, 'numero').slice(0, 80) || null,
    data_documento: data || null, valor_cents: valor, banco: texto(f, 'banco').slice(0, 80) || null, origem: 'manual', criado_por: user.id,
  });
  if (error) volta(f, 'erro', error.code === '23505' ? 'Já existe uma pendência com este tipo, número e data.' : 'Não foi possível criar a pendência.');
  await client.rpc('secretaria_auditar', { p_acao: 'Pendência criada', p_empresa: empresa, p_detalhe: `${TIPOS[tipo]}: ${descricao}` });
  volta(f, 'mensagem', 'Pendência criada.');
}

export async function acaoPendencias(f: FormData) {
  const { client } = await ownerSession();
  const ids = f.getAll('ids').map(String).filter(uuid);
  const acao = texto(f, 'acao');
  if (!ids.length) volta(f, 'erro', 'Escolha pelo menos uma pendência.');
  const { data, error } = await client.rpc('secretaria_pendencias_acao', { ids, acao });
  if (error) volta(f, 'erro', 'Não foi possível atualizar as pendências.');
  volta(f, 'mensagem', `${data} pendência${data === 1 ? '' : 's'} atualizada${data === 1 ? '' : 's'}.`);
}

export async function importarPendencias(empresa: string, periodoPedido: string, linhas: LinhaImportada[]):
  Promise<{ erro?: string; ok?: string }> {
  const { client, user } = await ownerSession();
  if (!uuid(empresa)) return { erro: 'Empresa inválida.' };
  if (!Array.isArray(linhas) || !linhas.length) return { erro: 'Não há linhas para importar.' };
  if (linhas.length > 2000) return { erro: 'O limite é de 2000 linhas por ficheiro.' };
  const limpas = linhas.flatMap((l) => {
    const descricao = String(l.descricao || '').trim().slice(0, 200);
    const data = /^\d{4}-\d{2}-\d{2}$/.test(String(l.data || '')) ? String(l.data) : null;
    const periodo = data ? data.slice(0, 7) : periodoPedido;
    if (!descricao || !TIPOS[l.tipo] || !/^\d{4}-(0[1-9]|1[0-2])$/.test(periodo)) return [];
    return [{ company_id: empresa, periodo: `${periodo}-01`, tipo: l.tipo, descricao, numero: l.numero ? String(l.numero).slice(0, 80) : null,
      data_documento: data, valor_cents: Number.isInteger(l.valor_cents) ? l.valor_cents : null, banco: l.banco ? String(l.banco).slice(0, 80) : null,
      origem: 'importacao', criado_por: user.id }];
  });
  if (!limpas.length) return { erro: 'Nenhuma linha tem data ou período válidos.' };
  const { data: existentes } = await client.from('secretaria_pendencias').select('tipo,numero,data_documento').eq('company_id', empresa).neq('estado', 'anulada').not('numero', 'is', null);
  const chave = (x: { tipo: string; numero: string | null; data_documento: string | null }) => `${x.tipo}|${x.numero}|${x.data_documento}`;
  const vistas = new Set((existentes ?? []).map(chave));
  const novas = limpas.filter((l) => {
    if (!l.numero || !l.data_documento) return true;
    if (vistas.has(chave(l))) return false;
    vistas.add(chave(l));
    return true;
  });
  for (let i = 0; i < novas.length; i += 500) {
    const { error } = await client.from('secretaria_pendencias').insert(novas.slice(i, i + 500));
    if (error) return { erro: 'A importação parou a meio. Confirme a lista antes de repetir.' };
  }
  const repetidas = limpas.length - novas.length;
  await client.rpc('secretaria_auditar', { p_acao: 'Importação', p_empresa: empresa, p_detalhe: `${novas.length} pendências importadas, ${repetidas} repetidas` });
  revalidatePath('/', 'layout');
  return { ok: `${novas.length} pendência${novas.length === 1 ? '' : 's'} importada${novas.length === 1 ? '' : 's'}${repetidas ? `, ${repetidas} já existia${repetidas === 1 ? '' : 'm'}` : ''}.` };
}

export async function gerarRecorrentes(f: FormData) {
  const { client } = await ownerSession();
  const periodo = texto(f, 'periodo');
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(periodo)) volta(f, 'erro', 'Escolha o mês.');
  const { data, error } = await client.rpc('secretaria_gerar_recorrentes', { p_periodo: `${periodo}-01` });
  if (error) volta(f, 'erro', 'Não foi possível criar as pendências.');
  volta(f, 'mensagem', data ? `${data} pendência${data === 1 ? '' : 's'} criada${data === 1 ? '' : 's'}.` : 'Já estavam todas criadas.');
}

export async function guardarRecorrente(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const tipo = texto(f, 'tipo');
  const descricao = texto(f, 'descricao').slice(0, 200);
  if (!uuid(empresa) || !TIPOS[tipo] || !descricao) volta(f, 'erro', 'Indique o tipo e a descrição.');
  const { error } = await client.from('secretaria_recorrentes').insert({ company_id: empresa, tipo, descricao, banco: texto(f, 'banco').slice(0, 80) || null });
  if (error) volta(f, 'erro', error.code === '23505' ? 'Esse documento já se repete todos os meses.' : 'Não foi possível guardar.');
  volta(f, 'mensagem', 'Documento recorrente acrescentado.');
}

export async function eliminarRecorrente(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'id');
  if (uuid(id)) await client.from('secretaria_recorrentes').delete().eq('id', id);
  volta(f, 'mensagem', 'Documento recorrente retirado.');
}

/* ------------------------------------------------------------ processos */

const ERROS_PROCESSO: [RegExp, string][] = [
  [/processo em curso/, 'Este cliente já tem um processo em curso.'],
  [/pendências em acompanhamento/, 'Não há pendências em acompanhamento para pedir.'],
  [/contacto principal/, 'Defina primeiro um contacto principal contactável.'],
  [/dia limite tem/, 'O dia limite tem de ser hoje ou depois.'],
  [/depois do dia limite/, 'O próximo envio do calendário seria depois do dia limite. Escolha enviar já ou um dia limite posterior.'],
];

export async function iniciarProcesso(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const limite = texto(f, 'limite');
  const quando = texto(f, 'quando');
  if (!uuid(empresa) || !/^\d{4}-\d{2}-\d{2}$/.test(limite)) volta(f, 'erro', 'Indique o dia limite.');
  const { data, error } = await client.rpc('secretaria_iniciar_processo', { empresa, limite, enviar_ja: quando !== 'proximo' });
  if (error) volta(f, 'erro', ERROS_PROCESSO.find(([r]) => r.test(error.message))?.[1] ?? 'Não foi possível iniciar o processo.');
  const r = data as { envio: string | null; estado: string | null };
  if (r.estado === 'a_enviar' && r.envio) {
    const e = await enviarPedido(r.envio);
    volta(f, e.ok ? 'mensagem' : 'erro', e.ok ? 'Processo iniciado. O pedido foi enviado.' : `O processo foi iniciado, mas o email não saiu: ${e.erro}`);
  }
  if (r.estado === 'por_aprovar') volta(f, 'mensagem', 'Processo iniciado. O pedido aguarda a sua aprovação.', `/secretaria/aprovar?e=${r.envio}`);
  volta(f, 'mensagem', 'Processo iniciado. O pedido sai no próximo envio do calendário.');
}

export async function cancelarProcesso(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'processo');
  if (!uuid(id)) volta(f, 'erro', 'Processo inválido.');
  const { error } = await client.rpc('secretaria_cancelar_processo', { p_processo: id });
  if (error) volta(f, 'erro', 'Não foi possível cancelar o processo.');
  volta(f, 'mensagem', 'Processo cancelado. Não sai mais nenhum email.');
}

export async function decidirEnvio(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'envio');
  const aprovar = texto(f, 'decisao') === 'aprovar';
  if (!uuid(id)) volta(f, 'erro', 'Pedido inválido.');
  const { error } = await client.rpc('secretaria_decidir_envio', { envio: id, aprovar, p_assunto: texto(f, 'assunto') || null, p_corpo: texto(f, 'corpo') || null });
  if (error) volta(f, 'erro', /já foi decidido/.test(error.message) ? 'Este pedido já tinha sido decidido.' : 'Não foi possível guardar a decisão.');
  if (!aprovar) volta(f, 'mensagem', 'Pedido rejeitado. O email não foi enviado.', '/secretaria/aprovar');
  const e = await enviarPedido(id);
  volta(f, e.ok ? 'mensagem' : 'erro', e.ok ? 'Email aprovado e enviado.' : `O email não saiu: ${e.erro}`, '/secretaria/aprovar');
}

/** Um lembrete já, sem esperar pelo calendário: serve quando o envio
    automático está desligado ou quando não se quer esperar. Passa pela mesma
    aprovação dos outros emails. */
export async function enviarLembrete(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'processo');
  if (!uuid(id)) volta(f, 'erro', 'Processo inválido.');
  const { data: p } = await client.from('secretaria_processos').select('id,company_id,estado,dia_limite').eq('id', id).maybeSingle();
  if (!p || p.estado !== 'em_curso') volta(f, 'erro', 'Este processo já terminou.');
  const { data: envios } = await client.from('secretaria_envios').select('id,tipo,estado').eq('processo_id', p.id);
  const espera = (envios ?? []).find((e) => e.estado === 'por_aprovar');
  if (espera) volta(f, 'mensagem', 'Já há um email deste cliente à espera da sua aprovação.', `/secretaria/aprovar?e=${espera.id}`);
  if ((envios ?? []).some((e) => e.estado === 'a_enviar')) volta(f, 'erro', 'Já há um email deste cliente a ser enviado. Aguarde um momento.');
  const { count } = await client.from('secretaria_pendencias').select('id', { count: 'exact', head: true }).eq('company_id', p.company_id).eq('estado', 'pendente').eq('acompanhar', true);
  if (!count) volta(f, 'erro', 'Não há pendências em acompanhamento para pedir.');

  const admin = adminClient();
  const tipo = (envios ?? []).some((e) => e.tipo === 'pedido' && e.estado === 'enviado') ? 'insistencia' : 'pedido';
  const { data: novo, error } = await admin.rpc('secretaria_novo_envio', { p_processo: p.id, p_tipo: tipo });
  if (error || !novo) volta(f, 'erro', 'Não foi possível preparar o lembrete.');
  await client.rpc('secretaria_auditar', { p_acao: 'Lembrete pedido', p_empresa: p.company_id, p_detalhe: tipo === 'pedido' ? 'Primeiro pedido, enviado à mão' : 'Insistência enviada à mão' });

  // O calendário recomeça a contar de agora: não sai outro lembrete amanhã.
  const { data: cadencia } = await admin.rpc('secretaria_cadencia_de', { empresa: p.company_id });
  const { data: proximo } = await admin.rpc('secretaria_proximo_envio', { cad: cadencia, depois: new Date().toISOString() });
  if (typeof proximo === 'string') {
    const dia = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date(proximo));
    await client.from('secretaria_processos').update({ proximo_envio: dia > p.dia_limite ? null : proximo }).eq('id', p.id).eq('estado', 'em_curso').not('proximo_envio', 'is', null);
  }

  const { data: criado } = await client.from('secretaria_envios').select('estado').eq('id', novo).maybeSingle();
  if (criado?.estado === 'por_aprovar') volta(f, 'mensagem', 'O lembrete aguarda a sua aprovação.', `/secretaria/aprovar?e=${novo}`);
  const e = await enviarPedido(String(novo));
  volta(f, e.ok ? 'mensagem' : 'erro', e.ok ? 'Lembrete enviado.' : `O lembrete não saiu: ${e.erro}`);
}

/** Desistir de um email que falhou, sem cancelar o processo. */
export async function descartarEnvio(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'envio');
  if (!uuid(id)) volta(f, 'erro', 'Envio inválido.');
  const { data, error } = await client.from('secretaria_envios')
    .update({ estado: 'rejeitado', decidido_em: new Date().toISOString(), erro: 'Descartado depois de falhar.' })
    .eq('id', id).eq('estado', 'falhou').select('company_id').maybeSingle();
  if (error || !data) volta(f, 'erro', 'Este envio já não pode ser descartado.');
  await client.rpc('secretaria_auditar', { p_acao: 'Email descartado', p_empresa: data.company_id, p_detalhe: 'Depois de falhar o envio.' });
  volta(f, 'mensagem', 'Email descartado.');
}

export async function repetirEnvio(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'envio');
  if (!uuid(id)) volta(f, 'erro', 'Envio inválido.');
  const { error } = await client.rpc('secretaria_repetir_envio', { envio: id });
  if (error) volta(f, 'erro', 'Este envio não pode ser repetido.');
  const e = await enviarPedido(id);
  volta(f, e.ok ? 'mensagem' : 'erro', e.ok ? 'Email enviado.' : `O email voltou a falhar: ${e.erro}`);
}

/* ------------------------------------------------------------ contactos */

/** Só pode haver um principal: tira-se o anterior e põe-se o novo. Se o
    segundo passo falhar, repõe-se o anterior. */
async function tornarPrincipal(client: SupabaseClient, empresa: string, id: string) {
  const { data: anterior } = await client.from('secretaria_contactos').select('id').eq('company_id', empresa).eq('principal', true).maybeSingle();
  if (anterior?.id === id) return true;
  if (anterior) await client.from('secretaria_contactos').update({ principal: false }).eq('id', anterior.id);
  const { error } = await client.from('secretaria_contactos').update({ principal: true, em_cc: false }).eq('id', id).eq('company_id', empresa);
  if (error && anterior) await client.from('secretaria_contactos').update({ principal: true }).eq('id', anterior.id);
  return !error;
}

export async function guardarContacto(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const nome = texto(f, 'nome').slice(0, 120);
  const email = texto(f, 'email').toLowerCase().slice(0, 254);
  if (!uuid(empresa) || !nome || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) volta(f, 'erro', 'Indique o nome e um email válido.');
  const principal = marcado(f, 'principal');
  // Primeiro grava-se o contacto; só depois passa a principal. Se a gravação
  // falhar (email repetido), o principal que lá estava não se perde.
  const { data: novo, error } = await client.from('secretaria_contactos')
    .insert({ company_id: empresa, nome, email, principal: false, em_cc: principal ? false : marcado(f, 'em_cc') }).select('id').maybeSingle();
  if (error || !novo) volta(f, 'erro', error?.code === '23505' ? 'Esse email já é um contacto deste cliente.' : 'Não foi possível guardar o contacto.');
  if (principal) await tornarPrincipal(client, empresa, novo.id);
  await client.rpc('secretaria_auditar', { p_acao: 'Contacto criado', p_empresa: empresa, p_detalhe: email });
  volta(f, 'mensagem', 'Contacto guardado.');
}

export async function mudarContacto(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'id');
  const empresa = texto(f, 'empresa');
  const campo = texto(f, 'campo');
  if (!uuid(id) || !uuid(empresa) || !['principal', 'em_cc', 'contactavel', 'eliminar'].includes(campo)) volta(f, 'erro', 'Contacto inválido.');
  if (campo === 'eliminar') {
    await client.from('secretaria_contactos').delete().eq('id', id).eq('company_id', empresa);
    await client.rpc('secretaria_auditar', { p_acao: 'Contacto eliminado', p_empresa: empresa, p_detalhe: id });
    volta(f, 'mensagem', 'Contacto eliminado.');
  }
  const valor = texto(f, 'valor') === 'true';
  if (campo === 'principal' && valor) {
    if (!(await tornarPrincipal(client, empresa, id))) volta(f, 'erro', 'Não foi possível mudar o contacto principal.');
  } else {
    const { error } = await client.from('secretaria_contactos').update({ [campo]: valor }).eq('id', id).eq('company_id', empresa);
    if (error) volta(f, 'erro', 'Não foi possível atualizar o contacto.');
  }
  await client.rpc('secretaria_auditar', { p_acao: 'Contacto atualizado', p_empresa: empresa, p_detalhe: `${campo}: ${valor ? 'sim' : 'não'}` });
  volta(f, 'mensagem', 'Contacto atualizado.');
}

export async function trazerContactosDoPortal(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  if (!uuid(empresa)) volta(f, 'erro', 'Empresa inválida.');
  type Ligacao = { active: boolean; profile: { email: string; full_name: string | null } | null };
  const [{ data: ligacoes }, { data: atuais }] = await Promise.all([
    client.from('company_users').select('active,profile:profiles(email,full_name)').eq('company_id', empresa),
    client.from('secretaria_contactos').select('email,principal').eq('company_id', empresa),
  ]);
  const vistos = new Set((atuais ?? []).map((c) => c.email.toLowerCase()));
  let temPrincipal = (atuais ?? []).some((c) => c.principal);
  let n = 0;
  for (const l of (ligacoes ?? []) as unknown as Ligacao[]) {
    const email = l.profile?.email?.toLowerCase();
    if (!l.active || !email || vistos.has(email)) continue;
    const { error } = await client.from('secretaria_contactos').insert({ company_id: empresa, nome: (l.profile?.full_name || email).slice(0, 120), email, principal: !temPrincipal });
    if (!error) { n++; temPrincipal = true; vistos.add(email); }
  }
  volta(f, 'mensagem', n ? `${n} contacto${n === 1 ? '' : 's'} acrescentado${n === 1 ? '' : 's'}.` : 'Os utilizadores do portal já estão todos nos contactos.');
}

/* ------------------------------------------------------------ modelos e definições */

export async function guardarModelo(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa') || null;
  const tipo = texto(f, 'tipo');
  const assunto = texto(f, 'assunto').slice(0, 250);
  const corpo = texto(f, 'corpo').slice(0, 8000);
  if ((empresa && !uuid(empresa)) || !['pedido', 'insistencia'].includes(tipo) || !assunto || !corpo) volta(f, 'erro', 'Preencha o assunto e o texto do email.');
  const q = client.from('secretaria_modelos').select('id').eq('tipo', tipo);
  const { data: existente } = await (empresa ? q.eq('company_id', empresa) : q.is('company_id', null)).maybeSingle();
  const agora = new Date().toISOString();
  const { error } = existente
    ? await client.from('secretaria_modelos').update({ assunto, corpo, atualizado_em: agora }).eq('id', existente.id)
    : await client.from('secretaria_modelos').insert({ company_id: empresa, tipo, assunto, corpo });
  if (error) volta(f, 'erro', 'Não foi possível guardar o modelo.');
  await client.rpc('secretaria_auditar', { p_acao: 'Modelo guardado', p_empresa: empresa, p_detalhe: tipo === 'pedido' ? 'Primeiro pedido' : 'Insistência' });
  volta(f, 'mensagem', 'Modelo guardado.');
}

export async function reporModelo(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const tipo = texto(f, 'tipo');
  if (!uuid(empresa) || !['pedido', 'insistencia'].includes(tipo)) volta(f, 'erro', 'Modelo inválido.');
  await client.from('secretaria_modelos').delete().eq('company_id', empresa).eq('tipo', tipo);
  volta(f, 'mensagem', 'Este cliente volta a usar o modelo do gabinete.');
}

export async function guardarDefinicoes(f: FormData) {
  const { client } = await ownerSession();
  const aprovar = texto(f, 'aprovar');
  const dia = Number(texto(f, 'dia_limite'));
  if (!['primeiro', 'todos', 'nenhum'].includes(aprovar) || !Number.isInteger(dia) || dia < 1 || dia > 28) volta(f, 'erro', 'Reveja a aprovação e o dia limite (de 1 a 28).');
  const { error } = await client.from('secretaria_definicoes').update({
    aprovar, dia_limite: dia, cadencia: lerCadencia(f), resumo_semanal: marcado(f, 'resumo_semanal'), atualizado_em: new Date().toISOString(),
  }).eq('id', true);
  if (error) volta(f, 'erro', 'Não foi possível guardar as definições.');
  await client.rpc('secretaria_auditar', { p_acao: 'Definições alteradas', p_empresa: null, p_detalhe: `Aprovação: ${aprovar}; dia limite: ${dia}` });
  volta(f, 'mensagem', 'Definições guardadas.');
}

export async function guardarCliente(f: FormData) {
  const { client } = await ownerSession();
  const empresa = texto(f, 'empresa');
  const periodicidade = texto(f, 'periodicidade');
  const dia = texto(f, 'dia_limite');
  if (!uuid(empresa) || !['mensal', 'trimestral', 'isento'].includes(periodicidade)) volta(f, 'erro', 'Reveja a periodicidade.');
  if (dia && (!Number.isInteger(Number(dia)) || Number(dia) < 1 || Number(dia) > 28)) volta(f, 'erro', 'O dia limite vai de 1 a 28.');
  const { error } = await client.from('secretaria_clientes').upsert({
    company_id: empresa, periodicidade, envio_automatico: marcado(f, 'envio_automatico'), dia_limite: dia ? Number(dia) : null,
    responsavel: texto(f, 'responsavel').slice(0, 120) || null, cadencia: marcado(f, 'proprio') ? lerCadencia(f) : null, atualizado_em: new Date().toISOString(),
  }, { onConflict: 'company_id' });
  if (error) volta(f, 'erro', 'Não foi possível guardar as definições do cliente.');
  await client.rpc('secretaria_auditar', { p_acao: 'Definições do cliente', p_empresa: empresa, p_detalhe: `Periodicidade: ${periodicidade}` });
  volta(f, 'mensagem', 'Definições do cliente guardadas.');
}

/* ------------------------------------------------------------ por identificar */

export async function arquivarDocumento(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'registo');
  const escolha = texto(f, 'pendencia');
  if (!uuid(id) || (escolha !== 'nenhuma' && !uuid(escolha))) volta(f, 'erro', 'Escolha a pendência, ou indique que não foi usado.');
  const { error } = await client.rpc('secretaria_arquivar_documento', { p_registo: id, p_pendencia: escolha === 'nenhuma' ? null : escolha });
  if (error) volta(f, 'erro', 'Não foi possível arquivar o documento.');
  volta(f, 'mensagem', 'Documento arquivado.');
}

export async function marcarRevisto(f: FormData) {
  const { client } = await ownerSession();
  const id = texto(f, 'registo');
  if (!uuid(id)) volta(f, 'erro', 'Documento inválido.');
  const { error } = await client.rpc('secretaria_marcar_revisto', { p_registo: id });
  if (error) volta(f, 'erro', 'Não foi possível marcar como revisto.');
  volta(f, 'mensagem', 'Documento marcado como revisto.');
}

/* ------------------------------------------------------------ procura global */

export async function procurar(termo: string): Promise<{ id: string; nome: string; nif: string }[]> {
  const { client } = await session();
  // Entre aspas, o termo pode ter vírgulas e pontos («Silva, Lda», «S.A.»).
  const q = String(termo || '').trim().replace(/["\\%]/g, '').slice(0, 60);
  if (q.length < 2) return [];
  const { data } = await client.from('companies').select('id,name,nif').or(`name.ilike."%${q}%",nif.ilike."%${q}%"`).eq('active', true).order('name').limit(8);
  return (data ?? []).map((c) => ({ id: c.id, nome: c.name, nif: c.nif }));
}
