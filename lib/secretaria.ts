/* A Secretária, sem servidor nem browser: os tipos, os nomes, os períodos e a
   composição dos emails. Serve a consola e os envios automáticos. */

export const TIPOS: Record<string, string> = {
  FT: 'Fatura', FS: 'Fatura simplificada', FR: 'Fatura-recibo', ND: 'Nota de débito', NC: 'Nota de crédito',
  RC: 'Recibo', MB: 'Movimento bancário', EB: 'Extrato bancário', OUTRO: 'Outro',
};

export const VARIAVEIS: { chave: string; nome: string }[] = [
  { chave: 'cliente', nome: 'Nome do cliente' },
  { chave: 'contacto', nome: 'Nome do contacto' },
  { chave: 'periodo', nome: 'Período' },
  { chave: 'numero', nome: 'N.º de documentos' },
  { chave: 'prazo', nome: 'Dia limite' },
  { chave: 'lista', nome: 'Lista por categoria' },
  { chave: 'documentos', nome: 'Lista curta' },
  { chave: 'remetente', nome: 'O seu nome' },
];

export const REMETENTE = 'Rúben Meirinho Rodrigues\nContabilista Certificado n.º 106297';

export type PendenciaAberta = {
  id: string; periodo: string; tipo: string; descricao: string;
  numero: string | null; data_documento: string | null; valor_cents: number | null; banco: string | null;
};

export type Cadencia =
  | { modo: 'corridos' | 'uteis'; intervalo: number; hora: number }
  | { modo: 'semana'; dias: Record<string, number>; hora?: number };

const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
export const DIAS_SEMANA: [string, string][] = [['1', 'Segunda'], ['2', 'Terça'], ['3', 'Quarta'], ['4', 'Quinta'], ['5', 'Sexta']];

export const euros = (c: number) => new Intl.NumberFormat('pt-PT', { style: 'currency', currency: 'EUR', useGrouping: 'always' } as Intl.NumberFormatOptions).format(c / 100);
export const dataPt = (iso?: string | null) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : '—');
export const dataHoraPt = (iso?: string | null) => (iso
  ? new Intl.DateTimeFormat('pt-PT', { timeZone: 'Europe/Lisbon', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso)).replace(',', ' às')
  : '—');
export const hojeLisboa = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Lisbon' }).format(new Date());
export const mesTexto = (iso: string) => `${MESES[Number(iso.slice(5, 7)) - 1]} de ${iso.slice(0, 4)}`;
export const maiuscula = (t: string) => t.charAt(0).toUpperCase() + t.slice(1);

/** «15/10/2026 – Fatura FT 1/1: Fornecedor – 123,45 €» */
export function linhaDocumento(p: PendenciaAberta) {
  const nome = [TIPOS[p.tipo] ?? p.tipo, p.numero].filter(Boolean).join(' ');
  return [p.data_documento ? dataPt(p.data_documento) : null, `${nome}: ${p.descricao}`, p.valor_cents != null ? euros(p.valor_cents) : null]
    .filter(Boolean).join(' – ');
}

export function porCategoria(lista: PendenciaAberta[]) {
  const faturas = lista.filter((p) => !['EB', 'MB', 'OUTRO'].includes(p.tipo));
  const bancos = lista.filter((p) => ['EB', 'MB'].includes(p.tipo));
  const outros = lista.filter((p) => p.tipo === 'OUTRO');
  return [{ titulo: 'Faturas em falta', itens: faturas }, { titulo: 'Bancos', itens: bancos }, { titulo: 'Outros documentos', itens: outros }]
    .filter((g) => g.itens.length);
}

/** O período de uma lista: «outubro de 2026», «de setembro a outubro de 2026». */
export function periodoDe(lista: PendenciaAberta[]) {
  const meses = [...new Set(lista.map((p) => p.periodo.slice(0, 7)))].sort();
  if (!meses.length) return '';
  if (meses.length === 1) return mesTexto(`${meses[0]}-01`);
  const [a, z] = [meses[0], meses[meses.length - 1]];
  return a.slice(0, 4) === z.slice(0, 4)
    ? `${MESES[Number(a.slice(5, 7)) - 1]} a ${mesTexto(`${z}-01`)}`
    : `${mesTexto(`${a}-01`)} a ${mesTexto(`${z}-01`)}`;
}

export function aplicar(texto: string, v: Record<string, string>) {
  return texto.replace(/\{\{\s*([a-z_]+)\s*\}\}/g, (tudo, k: string) => v[k] ?? tudo);
}

export function variaveisDoEmail(d: { empresa: string; contacto?: string | null; pendencias: PendenciaAberta[]; diaLimite?: string | null }) {
  return {
    cliente: d.empresa,
    contacto: d.contacto || 'Exmos. Senhores',
    periodo: periodoDe(d.pendencias),
    numero: String(d.pendencias.length),
    prazo: dataPt(d.diaLimite),
    remetente: REMETENTE,
    documentos: d.pendencias.map((p) => [p.tipo === 'OUTRO' ? '' : p.tipo, p.numero || p.descricao].filter(Boolean).join(' ')).join('; '),
    lista: porCategoria(d.pendencias).map((g) => `${g.titulo}: ${g.itens.map(linhaDocumento).join('; ')}`).join('\n'),
  };
}

export type Paragrafo = string | { lista: string; itens: string[] };

/** O email pronto: o assunto e os parágrafos, com a lista por categoria no
    lugar onde o modelo a pede. */
export function comporEmail(d: { tipo: string; assunto: string; corpo: string; empresa: string; contacto?: string | null; pendencias: PendenciaAberta[]; diaLimite?: string | null }) {
  const v = variaveisDoEmail(d);
  const paragrafos: Paragrafo[] = [];
  for (const bloco of d.corpo.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean)) {
    if (/^\{\{\s*lista\s*\}\}$/.test(bloco)) {
      for (const g of porCategoria(d.pendencias)) paragrafos.push({ lista: g.titulo, itens: g.itens.map(linhaDocumento) });
    } else {
      paragrafos.push(aplicar(bloco, v));
    }
  }
  return {
    assunto: aplicar(d.assunto, v).replace(/\s+/g, ' ').trim().slice(0, 250),
    titulo: d.tipo === 'pedido' ? 'Documentos em falta' : 'Lembrete: documentos em falta',
    paragrafos,
    rodape: 'Para entregar os documentos, use o botão acima. Se tiver alguma dúvida, pode responder a este email.',
  };
}

export type Periodo = { modo: string; chave: string; desde: string; ate: string; rotulo: string; anterior?: string; seguinte?: string };
const dois = (n: number) => String(n).padStart(2, '0');

/** O período da página. Sem nada pedido, todos: não se esconde o que falta. */
export function lerPeriodo(modo?: string, p?: string): Periodo {
  const hoje = hojeLisboa();
  let ano = Number(hoje.slice(0, 4));
  let mes = Number(hoje.slice(5, 7)) - 1;
  if (mes === 0) { ano--; mes = 12; }
  if (modo === 'trimestral') {
    const r = /^(\d{4})-T([1-4])$/.exec(p || '');
    const a = r ? Number(r[1]) : ano;
    const t = r ? Number(r[2]) : Math.ceil(mes / 3);
    return { modo: 'trimestral', chave: `${a}-T${t}`, desde: `${a}-${dois((t - 1) * 3 + 1)}-01`, ate: `${a}-${dois(t * 3)}-01`, rotulo: `${t}.º trimestre de ${a}`,
      anterior: t === 1 ? `${a - 1}-T4` : `${a}-T${t - 1}`, seguinte: t === 4 ? `${a + 1}-T1` : `${a}-T${t + 1}` };
  }
  if (modo === 'mensal') {
    const r = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(p || '');
    const a = r ? Number(r[1]) : ano;
    const m = r ? Number(r[2]) : mes;
    const iso = `${a}-${dois(m)}-01`;
    return { modo: 'mensal', chave: `${a}-${dois(m)}`, desde: iso, ate: iso, rotulo: maiuscula(mesTexto(iso)),
      anterior: m === 1 ? `${a - 1}-12` : `${a}-${dois(m - 1)}`, seguinte: m === 12 ? `${a + 1}-01` : `${a}-${dois(m + 1)}` };
  }
  return { modo: 'todos', chave: '', desde: '2000-01-01', ate: '2099-12-01', rotulo: 'Todos os períodos' };
}

export function cadenciaTexto(c?: Cadencia | null) {
  if (!c) return 'De 7 em 7 dias às 09:00';
  if (c.modo === 'semana') {
    const dias = DIAS_SEMANA.filter(([k]) => c.dias?.[k] != null).map(([k, n]) => `${n.slice(0, 3)} ${dois(c.dias[k])}:00`);
    return dias.length ? dias.join(' · ') : 'Sem dias escolhidos';
  }
  return `De ${c.intervalo} em ${c.intervalo} dias ${c.modo === 'uteis' ? 'úteis ' : ''}às ${dois(c.hora)}:00`;
}

export const MOTIVOS: Record<string, string> = {
  nada_falta: 'Não falta nada', dia_limite: 'Dia limite', cancelado: 'Cancelado', sem_documentos: 'Sem documentos', sem_contacto: 'Sem contacto',
};

export const ESTADOS_PENDENCIA: Record<string, { nome: string; classe: string }> = {
  pendente: { nome: 'Pendente', classe: 'etiqueta etiqueta-critico' },
  recebida: { nome: 'Recebida', classe: 'etiqueta etiqueta-atencao' },
  associada: { nome: 'Associada', classe: 'etiqueta etiqueta-positivo' },
  anulada: { nome: 'Anulada', classe: 'etiqueta' },
};

export const ESTADOS_ENVIO: Record<string, { nome: string; classe: string }> = {
  por_aprovar: { nome: 'Por aprovar', classe: 'etiqueta etiqueta-atencao' },
  rejeitado: { nome: 'Rejeitado', classe: 'etiqueta' },
  a_enviar: { nome: 'A enviar', classe: 'etiqueta' },
  enviado: { nome: 'Enviado', classe: 'etiqueta etiqueta-positivo' },
  falhou: { nome: 'Falhou', classe: 'etiqueta etiqueta-critico' },
};

export const PRAZOS: Record<string, { nome: string; classe: string }> = {
  em_dia: { nome: 'Em dia', classe: 'etiqueta etiqueta-positivo' },
  apertado: { nome: 'Apertado', classe: 'etiqueta etiqueta-atencao' },
  em_risco: { nome: 'Em risco', classe: 'etiqueta etiqueta-critico' },
  fora: { nome: 'Fora de prazo', classe: 'etiqueta etiqueta-critico' },
};

export type ClienteResumo = {
  id: string; nome: string; nif: string; periodicidade: string; automatico: boolean; responsavel: string | null;
  total: number; recebidas: number; em_falta: number; em_falta_total: number; por_aprovar: number; tem_contacto: boolean;
  processo: { id: string; dia_limite: string; proximo_envio: string | null; iniciado_em: string; insistencias: number } | null;
  ultimo_motivo: string | null; ultimo_contacto: string | null; limite: string;
  prazo: string | null; resposta: string | null; sem_resposta_dias: number | null;
};

/** A coluna «Resposta» numa palavra. */
export function respostaTexto(c: ClienteResumo) {
  switch (c.resposta) {
    case 'respondeu': return 'Respondeu';
    case 'sem_resposta': return c.sem_resposta_dias ? `Sem resposta há ${c.sem_resposta_dias} d` : 'Sem resposta';
    case 'nao_obtida': return 'Resposta não obtida';
    case 'por_aprovar': return 'Por aprovar';
    default: return '—';
  }
}

/** Limite sugerido: o dia configurado do mês seguinte ao último período em falta. */
export function limiteSugerido(dia: number, periodos: string[]) {
  const hoje = hojeLisboa();
  const ultimo = [...periodos].sort().pop() || hoje.slice(0, 7);
  let a = Number(ultimo.slice(0, 4));
  let m = Number(ultimo.slice(5, 7)) + 1;
  if (m === 13) { a++; m = 1; }
  let data = `${a}-${dois(m)}-${dois(dia)}`;
  while (data < hoje) {
    m++;
    if (m === 13) { a++; m = 1; }
    data = `${a}-${dois(m)}-${dois(dia)}`;
  }
  return data;
}

const CABECALHOS: Record<string, string[]> = {
  descricao: ['descricao', 'fornecedor', 'entidade', 'nome', 'cliente fornecedor', 'terceiro', 'emissor'],
  tipo: ['tipo de documento', 'tipo', 'tipo doc', 'doc'],
  numero: ['n o do documento', 'n do documento', 'numero do documento', 'numero', 'n o', 'n documento', 'documento', 'n doc'],
  data: ['data do documento', 'data', 'data doc', 'data documento'],
  valor: ['valor', 'total', 'montante', 'valor total', 'total documento'],
  banco: ['banco', 'conta bancaria'],
};
const norma = (t: string) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

export type LinhaImportada = { descricao: string; tipo: string; numero: string | null; data: string | null; valor_cents: number | null; banco: string | null };
export type Importacao = { linhas: LinhaImportada[]; recusadas: { linha: number; motivo: string }[]; colunas: string[] };

function lerTipo(v: string) {
  const t = norma(v);
  if (!t) return 'FT';
  const sigla = t.toUpperCase().split(' ')[0];
  if (TIPOS[sigla]) return sigla;
  if (t.includes('simplificada')) return 'FS';
  if (t.includes('fatura recibo') || t.includes('factura recibo')) return 'FR';
  if (t.includes('debito')) return 'ND';
  if (t.includes('credito')) return 'NC';
  if (t.includes('extrato')) return 'EB';
  if (t.includes('movimento') || t.includes('banc')) return 'MB';
  if (t.includes('recibo')) return 'RC';
  if (t.includes('fatura') || t.includes('factura')) return 'FT';
  return 'OUTRO';
}

export function lerData(v: string): string | null {
  const t = v.trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})/.exec(t);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(t);
  if (m) return `${m[3]}-${dois(Number(m[2]))}-${dois(Number(m[1]))}`;
  if (/^\d{5}(\.\d+)?$/.test(t)) return new Date(Date.UTC(1899, 11, 30) + Math.floor(Number(t)) * 86400000).toISOString().slice(0, 10);
  return null;
}

export function lerValor(v: string): number | null {
  let t = v.replace(/[€\s ]/g, '');
  if (!t) return null;
  if (t.includes(',') && t.includes('.')) t = t.lastIndexOf(',') > t.lastIndexOf('.') ? t.replace(/\./g, '').replace(',', '.') : t.replace(/,/g, '');
  else t = t.replace(',', '.');
  const n = Number(t);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

/** De uma folha (linhas de células) às pendências a importar, com o motivo de
    cada linha que não entra. Procura o cabeçalho nas primeiras linhas: os
    relatórios costumam trazer títulos antes da tabela. */
export function interpretarFolha(folha: string[][]): Importacao {
  let inicio = -1;
  const colunas: Record<string, number> = {};
  for (let i = 0; i < Math.min(folha.length, 25) && inicio < 0; i++) {
    const celulas = folha[i].map(norma);
    const achadas: Record<string, number> = {};
    for (const [campo, nomes] of Object.entries(CABECALHOS)) {
      const n = celulas.findIndex((c) => c && nomes.includes(c));
      if (n >= 0) achadas[campo] = n;
    }
    if (achadas.descricao !== undefined && Object.keys(achadas).length >= 2) { inicio = i; Object.assign(colunas, achadas); }
  }
  if (inicio < 0) return { linhas: [], recusadas: [{ linha: 0, motivo: 'Não encontrámos o cabeçalho: precisa de uma coluna Descrição (ou Fornecedor) e de pelo menos outra.' }], colunas: [] };

  const linhas: LinhaImportada[] = [];
  const recusadas: { linha: number; motivo: string }[] = [];
  const cel = (l: string[], c: string) => (colunas[c] === undefined ? '' : String(l[colunas[c]] ?? '').trim());
  folha.slice(inicio + 1).forEach((l, i) => {
    if (l.every((c) => !String(c ?? '').trim())) return;
    const linha = inicio + i + 2;
    const descricao = cel(l, 'descricao').slice(0, 200);
    if (!descricao) { recusadas.push({ linha, motivo: 'sem descrição' }); return; }
    if (/^total/i.test(descricao)) return;
    const textoData = cel(l, 'data');
    const data = textoData ? lerData(textoData) : null;
    if (textoData && !data) { recusadas.push({ linha, motivo: `data inválida (${textoData})` }); return; }
    const textoValor = cel(l, 'valor');
    const valor = textoValor ? lerValor(textoValor) : null;
    if (textoValor && valor === null) { recusadas.push({ linha, motivo: `valor inválido (${textoValor})` }); return; }
    linhas.push({ descricao, tipo: lerTipo(cel(l, 'tipo')), numero: cel(l, 'numero').slice(0, 80) || null, data, valor_cents: valor, banco: cel(l, 'banco').slice(0, 80) || null });
  });
  return { linhas, recusadas, colunas: Object.keys(colunas) };
}
