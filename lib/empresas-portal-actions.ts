'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { ownerSession } from './auth';
import { adminClient, adminConfigured } from './admin-client';
import { apagarCredenciaisEmpresa, gravarCredenciaisEmpresa, testarCegidEmpresa } from './cegid-empresas';
import { enviarEmail } from './email';
import { uuid } from './data';

/* As ações da gestão sobre o portal Empresas: data de corte, ligação ao Cegid
   de cada empresa, revisão dos documentos do mês, mensagens e prazos. A base
   volta a verificar o contabilista em cada função. */

const texto = (form: FormData, nome: string) => String(form.get(nome) || '').trim();
const PORTAL = (process.env.NEXT_PUBLIC_EMPRESAS_URL || 'https://portal.rr-contabilidade.com').replace(/\/$/, '');

function voltar(empresa: string, chave: 'erro' | 'mensagem', mensagem: string, extra = ''): never {
  revalidatePath(`/empresas/${empresa}`);
  revalidatePath('/empresas');
  redirect(`/empresas/${empresa}?${chave}=${encodeURIComponent(mensagem)}${extra}`);
}

async function empresaDoForm(form: FormData) {
  const sessao = await ownerSession();
  const id = texto(form, 'empresa');
  if (!uuid(id)) redirect('/empresas?erro=Empresa%20inv%C3%A1lida.');
  return { ...sessao, id };
}

export async function definirDataCorte(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const valor = texto(form, 'data_corte');
  const corte = valor ? valor : null;
  if (corte && !/^\d{4}-\d{2}-\d{2}$/.test(corte)) voltar(id, 'erro', 'Data inválida.');
  const { error } = await client.rpc('definir_data_corte', { empresa: id, corte, nota: texto(form, 'nota') || null });
  if (error) voltar(id, 'erro', /futura/.test(error.message) ? 'A data de corte não pode ser futura.' : 'Não foi possível guardar a data de corte.');
  voltar(id, 'mensagem', corte ? 'Data de corte guardada. O portal já só mostra saldos e balancetes até essa data.' : 'Data de corte retirada: o portal deixa de mostrar saldos e balancetes.');
}

export async function guardarCegidEmpresa(form: FormData) {
  const { client, user, id } = await empresaDoForm(form);
  const identificador = texto(form, 'identificador');
  const segredo = texto(form, 'segredo');
  const url = (v: string) => { try { const u = new URL(v); return u.protocol === 'https:' ? u.origin + u.pathname.replace(/\/$/, '') : null; } catch { return null; } };
  const oauth = texto(form, 'oauth_url'), api = texto(form, 'api_url');
  if (!identificador || !segredo || identificador.length > 500 || segredo.length > 2000) voltar(id, 'erro', 'Indique o identificador e o segredo da API desta empresa.');
  if ((oauth && !url(oauth)) || (api && !url(api))) voltar(id, 'erro', 'Os endereços do Cegid têm de começar por https://.');
  if (!adminConfigured()) voltar(id, 'erro', 'Falta a chave de serviço do Supabase nesta aplicação.');
  const { data: existe } = await client.from('companies').select('id').eq('id', id).maybeSingle();
  if (!existe) voltar(id, 'erro', 'Empresa indisponível.');
  try {
    await gravarCredenciaisEmpresa(id, { identificador, segredo, oauth_url: oauth ? url(oauth)! : undefined, api_url: api ? url(api)! : undefined });
  } catch {
    voltar(id, 'erro', 'Não foi possível guardar. Confirme a chave de cifragem privada.');
  }
  await adminClient().from('management_audit').insert({ actor_id: user.id, action: 'company_credentials_updated:' + id });
  const teste = await testarCegidEmpresa(id);
  if (!teste.ok) voltar(id, 'erro', `Credenciais guardadas, mas o Cegid não as aceitou: ${teste.erro}`);
  voltar(id, 'mensagem', `Ligação ao Cegid confirmada. Exercícios: ${teste.exercicios.join(', ') || 'nenhum'}.`);
}

export async function testarCegid(form: FormData) {
  const { id } = await empresaDoForm(form);
  const teste = await testarCegidEmpresa(id);
  if (!teste.ok) voltar(id, 'erro', teste.erro);
  voltar(id, 'mensagem', `Ligação ao Cegid a funcionar. Exercícios: ${teste.exercicios.join(', ') || 'nenhum'}.`);
}

export async function apagarCegid(form: FormData) {
  const { user, id } = await empresaDoForm(form);
  if (!adminConfigured()) voltar(id, 'erro', 'Falta a chave de serviço do Supabase nesta aplicação.');
  await apagarCredenciaisEmpresa(id);
  await adminClient().from('management_audit').insert({ actor_id: user.id, action: 'company_credentials_removed:' + id });
  voltar(id, 'mensagem', 'Credenciais do Cegid apagadas desta empresa.');
}

export async function reverDocumento(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const estado = texto(form, 'estado');
  const mes = texto(form, 'mes');
  const { error } = await client.rpc('rever_documento_empresa', {
    documento: texto(form, 'documento'), novo_estado: estado, resposta: texto(form, 'resposta') || null,
  });
  if (error) voltar(id, 'erro', 'Não foi possível atualizar o documento.', `&mes=${mes}`);
  voltar(id, 'mensagem', estado === 'devolvido' ? 'Documento devolvido ao cliente.' : estado === 'visto' ? 'Documento marcado como visto.' : 'Documento reposto como recebido.', `&mes=${mes}`);
}

export async function marcarTodosVistos(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const mes = texto(form, 'mes');
  const { data } = await client.from('empresa_documentos').select('id').eq('company_id', id).eq('mes', `${mes}-01`).eq('estado', 'recebido');
  for (const d of data ?? []) await client.rpc('rever_documento_empresa', { documento: d.id, novo_estado: 'visto', resposta: null });
  voltar(id, 'mensagem', `${data?.length ?? 0} documentos marcados como vistos.`, `&mes=${mes}`);
}

export async function conferirMes(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const mes = texto(form, 'mes');
  const conferido = texto(form, 'conferido') === 'true';
  const { error } = await client.rpc('conferir_mes_empresa', { empresa: id, mes: `${mes}-01`, conferido, nota: texto(form, 'nota') || null });
  if (error) voltar(id, 'erro', 'Não foi possível guardar a conferência.', `&mes=${mes}`);
  voltar(id, 'mensagem', conferido ? 'Mês conferido. O cliente vê-o no portal.' : 'Conferência anulada.', `&mes=${mes}`);
}

export async function responderMensagem(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const corpo = String(form.get('corpo') || '').trim();
  if (!corpo || corpo.length > 5000) voltar(id, 'erro', 'Escreva a resposta (até 5000 caracteres).', '#mensagens');
  const { data: mensagem, error } = await client.rpc('enviar_mensagem_empresa', { empresa: id, corpo });
  if (error || !mensagem) voltar(id, 'erro', 'Não foi possível enviar a resposta.', '#mensagens');
  await client.rpc('ler_mensagens_empresa', { empresa: id });

  // Avisa por email as pessoas com acesso à empresa.
  const { data: empresa } = await client.from('companies')
    .select('name,company_users(active,profile:profiles(email,full_name))').eq('id', id).maybeSingle();
  type Ligacao = { active: boolean; profile: { email: string; full_name: string | null } | null };
  for (const l of ((empresa?.company_users ?? []) as unknown as Ligacao[]).filter((x) => x.active && x.profile?.email)) {
    await enviarEmail({
      chave: `empresa-resposta:${mensagem}:${l.profile!.email}`,
      para: l.profile!.email,
      assunto: `Nova mensagem do contabilista — ${empresa?.name ?? 'a sua empresa'}`,
      titulo: 'Tem uma mensagem nova.',
      paragrafos: [`O contabilista respondeu sobre ${empresa?.name ?? 'a sua empresa'}. Abra o portal para ler e responder.`],
      botao: { texto: 'Abrir as mensagens', url: `${PORTAL}/app/${id}/mensagens` },
    });
  }
  voltar(id, 'mensagem', 'Resposta enviada.', '#mensagens');
}

export async function criarPrazo(form: FormData) {
  const { client, user, id } = await empresaDoForm(form);
  const titulo = texto(form, 'titulo').slice(0, 200);
  const data = texto(form, 'data');
  const todas = form.get('todas') === 'on';
  if (!titulo || !/^\d{4}-\d{2}-\d{2}$/.test(data)) voltar(id, 'erro', 'Indique o título e a data do prazo.', '#prazos');
  const { error } = await client.from('empresa_prazos').insert({
    company_id: todas ? null : id, titulo, data, descricao: texto(form, 'descricao').slice(0, 1000) || null, criado_por: user.id,
  });
  if (error) voltar(id, 'erro', 'Não foi possível criar o prazo.', '#prazos');
  voltar(id, 'mensagem', todas ? 'Prazo criado para todas as empresas.' : 'Prazo criado.', '#prazos');
}

export async function apagarPrazo(form: FormData) {
  const { client, id } = await empresaDoForm(form);
  const prazo = texto(form, 'prazo');
  if (!uuid(prazo)) voltar(id, 'erro', 'Prazo inválido.', '#prazos');
  const { error } = await client.from('empresa_prazos').delete().eq('id', prazo);
  if (error) voltar(id, 'erro', 'Não foi possível apagar o prazo.', '#prazos');
  voltar(id, 'mensagem', 'Prazo apagado.', '#prazos');
}
