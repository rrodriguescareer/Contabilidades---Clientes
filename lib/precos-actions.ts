'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { ownerSession } from './auth';

const texto = (f: FormData, c: string, max = 200) => String(f.get(c) || '').trim().slice(0, max);
const ligado = (f: FormData, c: string) => f.get(c) === 'on';
/** Euros escritos com vírgula ou ponto, guardados em cêntimos. */
const cents = (f: FormData, c: string) => {
  const n = Math.round(Number(String(f.get(c) || '0').replace(',', '.')) * 100);
  return Number.isFinite(n) && n >= 0 ? n : 0;
};
const quando = (f: FormData, c: string) => {
  const v = texto(f, c, 30);
  return v ? new Date(v).toISOString() : null;
};

function sair(caminho: string, mensagem: string, erro = false): never {
  redirect(`${caminho}?${erro ? 'erro' : 'mensagem'}=${encodeURIComponent(mensagem)}`);
}

/* ------------------------------------------------------------- preços */
const CAMPOS = [
  'base', 'varios_titulares', 'a_e_b', 'b_adicional',
  'rendas_unica', 'rendas_ate2', 'rendas_ate5', 'rendas_mais',
  'mais_valias_titulos', 'mais_valias_imovel',
] as const;

export async function guardarPolitica(form: FormData) {
  const { client } = await ownerSession();
  const nome = texto(form, 'nome', 120);
  if (nome.length < 2) sair('/precos', 'Dê um nome à política.', true);

  const valores = Object.fromEntries(CAMPOS.map((c) => [c, cents(form, c)]));
  if (valores.base <= 0) sair('/precos', 'O preço base tem de ser maior do que zero.', true);

  const { data, error } = await client
    .from('pricing_policies')
    .insert({ nome, valores, notas: texto(form, 'notas', 500) })
    .select('id')
    .single();
  if (error || !data) sair('/precos', 'Não foi possível guardar a política.', true);

  if (ligado(form, 'activar')) await activar(data.id);
  revalidatePath('/precos');
  sair('/precos', 'Política de preços guardada.');
}

/** Activar é trocar: só pode haver uma em vigor. */
async function activar(id: string) {
  const { client } = await ownerSession();
  await client.from('pricing_policies').update({ activa: false }).eq('activa', true);
  await client.from('pricing_policies').update({ activa: true }).eq('id', id);
}

export async function activarPolitica(form: FormData) {
  await ownerSession();
  const id = texto(form, 'id', 40);
  if (!id) sair('/precos', 'Política inválida.', true);
  await activar(id);
  revalidatePath('/precos');
  sair('/precos', 'Política em vigor.');
}

/* ---------------------------------------------------------- campanhas */
export async function guardarCampanha(form: FormData) {
  const { client } = await ownerSession();
  const tipo = texto(form, 'tipo', 20) === 'fixo' ? 'fixo' : 'percentagem';
  const bruto = Number(String(form.get('valor') || '0').replace(',', '.'));
  const valor = tipo === 'percentagem' ? Math.round(bruto) : Math.round(bruto * 100);

  if (!Number.isFinite(valor) || valor <= 0 || (tipo === 'percentagem' && valor > 100)) {
    sair('/precos', 'Indique um desconto válido.', true);
  }

  const { error } = await client.from('campaigns').insert({
    nome: texto(form, 'nome', 120),
    rotulo_publico: texto(form, 'rotulo_publico', 160),
    tipo,
    valor,
    activa: ligado(form, 'activar'),
    inicio: quando(form, 'inicio'),
    fim: quando(form, 'fim'),
  });
  if (error) sair('/precos', 'Não foi possível guardar a campanha.', true);
  revalidatePath('/precos');
  sair('/precos', 'Campanha guardada.');
}

export async function alternarCampanha(form: FormData) {
  const { client } = await ownerSession();
  const id = texto(form, 'id', 40);
  const activa = texto(form, 'activa', 10) === 'true';
  await client.from('campaigns').update({ activa: !activa }).eq('id', id);
  revalidatePath('/precos');
  sair('/precos', activa ? 'Campanha desligada.' : 'Campanha ligada.');
}

/* ------------------------------------------------------------- avisos */
export async function guardarAviso(form: FormData) {
  const { client } = await ownerSession();
  const mensagem = texto(form, 'mensagem', 400);
  if (mensagem.length < 5) sair('/avisos', 'Escreva a mensagem do aviso.', true);

  const { error } = await client.from('avisos').insert({
    mensagem,
    tom: ['info', 'atencao', 'critico'].includes(texto(form, 'tom', 10)) ? texto(form, 'tom', 10) : 'info',
    activo: ligado(form, 'activar'),
    inicio: quando(form, 'inicio'),
    fim: quando(form, 'fim'),
    no_irs: ligado(form, 'no_irs'),
    no_website: ligado(form, 'no_website'),
  });
  if (error) sair('/avisos', 'Não foi possível guardar o aviso.', true);
  revalidatePath('/avisos');
  sair('/avisos', 'Aviso guardado.');
}

export async function alternarAviso(form: FormData) {
  const { client } = await ownerSession();
  const id = texto(form, 'id', 40);
  const activo = texto(form, 'activo', 10) === 'true';
  await client.from('avisos').update({ activo: !activo }).eq('id', id);
  revalidatePath('/avisos');
  sair('/avisos', activo ? 'Aviso desligado.' : 'Aviso no ar.');
}

export async function apagarAviso(form: FormData) {
  const { client } = await ownerSession();
  await client.from('avisos').delete().eq('id', texto(form, 'id', 40));
  revalidatePath('/avisos');
  sair('/avisos', 'Aviso apagado.');
}
