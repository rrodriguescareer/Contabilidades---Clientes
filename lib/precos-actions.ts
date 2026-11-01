'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { ownerSession } from './auth';
import type { Regra } from './precos-regras';

const texto = (f: FormData, c: string, max = 200) => String(f.get(c) || '').trim().slice(0, max);
const ligado = (f: FormData, c: string) => f.get(c) === 'on';
const quando = (f: FormData, c: string) => {
  const v = texto(f, c, 30);
  return v ? new Date(v).toISOString() : null;
};

function sair(caminho: string, mensagem: string, erro = false): never {
  redirect(`${caminho}?${erro ? 'erro' : 'mensagem'}=${encodeURIComponent(mensagem)}`);
}

/* ------------------------------------------------------------- preços */
/* Cada política é uma versão: gravar cria uma nova, nunca altera uma que já
   existe. Pôr em vigor fica no histórico, e qualquer versão antiga pode
   voltar a vigorar. A base valida as regras e calcula o preço. */

type DadosPolitica = {
  nome: string; notas?: string; regras: Regra[]; minimo?: number | null; maximo?: number | null;
  origem?: string | null; ativar?: boolean;
};

const centimos = (v: unknown) => {
  if (v == null || v === '') return null;
  const n = Math.round(Number(v));
  return Number.isFinite(n) && n >= 0 ? n : null;
};

export async function criarPoliticaRegras(d: DadosPolitica): Promise<{ ok?: string; erro?: string; id?: string }> {
  const { client } = await ownerSession();
  const regras = Array.isArray(d?.regras) ? d.regras.map((r, i) => ({ ...r, ordem: (i + 1) * 10 })) : [];
  const { data: id, error } = await client.rpc('criar_politica_precos', {
    p_nome: String(d?.nome || '').slice(0, 120), p_regras: regras, p_notas: String(d?.notas || '').slice(0, 500) || null,
    p_minimo: centimos(d?.minimo), p_maximo: centimos(d?.maximo), p_origem: d?.origem || null,
  });
  if (error || !id) return { erro: error?.code === '22023' ? error.message : 'Não foi possível guardar a política.' };
  if (d.ativar) {
    const { error: semAtivar } = await client.rpc('ativar_politica_precos', { p_id: id });
    if (semAtivar) return { erro: 'Política guardada, mas não foi possível pô-la em vigor.', id };
  }
  revalidatePath('/precos');
  return { ok: d.ativar ? 'Política guardada e em vigor.' : 'Política guardada. Ponha-a em vigor quando quiser, no histórico.', id };
}

export async function simularPreco(regras: Regra[], medidas: Record<string, unknown>, minimo?: number | null, maximo?: number | null) {
  const { client } = await ownerSession();
  const ordenadas = (Array.isArray(regras) ? regras : []).map((r, i) => ({ ...r, ordem: (i + 1) * 10 }));
  const { data, error } = await client.rpc('simular_preco', { regras: ordenadas, medidas, minimo: centimos(minimo), maximo: centimos(maximo) });
  if (error) return { erro: 'Não foi possível simular.' };
  return data as { erro?: string; items?: { code: string; label: string; amount_cents: number }[]; subtotal_cents?: number };
}

export async function ativarPoliticaPrecos(form: FormData) {
  const { client } = await ownerSession();
  const { error } = await client.rpc('ativar_politica_precos', { p_id: texto(form, 'id', 40) });
  if (error) sair('/precos', 'Não foi possível pôr a política em vigor.', true);
  revalidatePath('/precos');
  sair('/precos', 'Política em vigor. Os orçamentos novos já usam estes preços.');
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
