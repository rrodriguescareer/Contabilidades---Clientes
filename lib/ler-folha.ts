/* Ler Excel e CSV no browser, sem bibliotecas: um .xlsx é um zip de XML. O
   ficheiro nunca sai do computador; só as linhas confirmadas vão ao servidor. */

async function inflar(dados: Uint8Array) {
  const fluxo = new Blob([dados as BlobPart]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(fluxo).arrayBuffer());
}

async function abrirZip(b: Uint8Array) {
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let fim = b.length - 22;
  while (fim >= 0 && v.getUint32(fim, true) !== 0x06054b50) fim--;
  if (fim < 0) throw new Error('Ficheiro Excel inválido.');
  const n = v.getUint16(fim + 10, true);
  let p = v.getUint32(fim + 16, true);
  const entradas = new Map<string, () => Promise<Uint8Array>>();
  const nomes = new TextDecoder();
  for (let i = 0; i < n; i++) {
    const metodo = v.getUint16(p + 10, true);
    const comprimido = v.getUint32(p + 20, true);
    const tn = v.getUint16(p + 28, true);
    const te = v.getUint16(p + 30, true);
    const tc = v.getUint16(p + 32, true);
    const local = v.getUint32(p + 42, true);
    const nome = nomes.decode(b.subarray(p + 46, p + 46 + tn));
    entradas.set(nome, async () => {
      const inicio = local + 30 + v.getUint16(local + 26, true) + v.getUint16(local + 28, true);
      const dados = b.subarray(inicio, inicio + comprimido);
      return metodo === 0 ? dados : inflar(dados);
    });
    p += 46 + tn + te + tc;
  }
  return entradas;
}

const coluna = (ref: string) => {
  let c = 0;
  for (const l of ref.replace(/\d+/g, '')) c = c * 26 + l.charCodeAt(0) - 64;
  return c - 1;
};

async function lerXlsx(b: Uint8Array) {
  const zip = await abrirZip(b);
  const xml = async (nome: string) => {
    const f = zip.get(nome);
    return f ? new DOMParser().parseFromString(new TextDecoder().decode(await f()), 'application/xml') : null;
  };
  const partilhadas = await xml('xl/sharedStrings.xml');
  const textos = partilhadas ? Array.from(partilhadas.getElementsByTagName('si')).map((si) => Array.from(si.getElementsByTagName('t')).map((t) => t.textContent ?? '').join('')) : [];

  // A primeira folha, pela ordem do livro.
  const livro = await xml('xl/workbook.xml');
  const relacoes = await xml('xl/_rels/workbook.xml.rels');
  const rid = livro?.getElementsByTagName('sheet')[0]?.getAttribute('r:id');
  const alvo = rid && relacoes ? Array.from(relacoes.getElementsByTagName('Relationship')).find((r) => r.getAttribute('Id') === rid)?.getAttribute('Target') : null;
  const caminho = alvo ? (alvo.startsWith('/') ? alvo.slice(1) : `xl/${alvo}`) : 'xl/worksheets/sheet1.xml';
  const folha = await xml(caminho);
  if (!folha) throw new Error('Não encontrámos a folha do Excel.');

  // O Excel não grava as linhas vazias: repõem-se, para o número de cada linha
  // ser o que a pessoa vê na folha quando se diz qual não entrou.
  const linhas: string[][] = [];
  for (const linha of Array.from(folha.getElementsByTagName('row'))) {
    const numero = Number(linha.getAttribute('r')) || linhas.length + 1;
    if (numero > 20_000) break;
    while (linhas.length < numero - 1) linhas.push([]);
    const celulas: string[] = [];
    for (const c of Array.from(linha.getElementsByTagName('c'))) {
      const i = coluna(c.getAttribute('r') || 'A');
      const tipo = c.getAttribute('t');
      const valor = c.getElementsByTagName('v')[0]?.textContent ?? '';
      celulas[i] = tipo === 's' ? textos[Number(valor)] ?? ''
        : tipo === 'inlineStr' ? Array.from(c.getElementsByTagName('t')).map((t) => t.textContent ?? '').join('')
        // Um número do Excel vem sempre com ponto decimal (12.345 é doze euros
        // e pouco): passa a vírgula, para não ser lido como milhares.
        : (!tipo || tipo === 'n') && /^-?\d+(\.\d+)?(e[+-]?\d+)?$/i.test(valor) ? String(Number(valor)).replace('.', ',')
        : valor;
    }
    linhas.push(Array.from(celulas, (x) => x ?? ''));
  }
  return linhas;
}

function descodificar(b: Uint8Array) {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(b); }
  catch { return new TextDecoder('windows-1252').decode(b); }
}

function lerCsv(texto: string) {
  const limpo = texto.replace(/^﻿/, '').replace(/\r\n?/g, '\n');
  const amostra = limpo.split('\n').slice(0, 30).join('\n');
  const sep = [';', '\t', ','].map((c) => [c, amostra.split(c).length] as const).sort((a, b) => b[1] - a[1])[0][0];
  const linhas: string[][] = [];
  let linha: string[] = [];
  let campo = '';
  let aspas = false;
  for (let i = 0; i < limpo.length; i++) {
    const c = limpo[i];
    if (aspas) {
      if (c === '"' && limpo[i + 1] === '"') { campo += '"'; i++; }
      else if (c === '"') aspas = false;
      else campo += c;
    } else if (c === '"') aspas = true;
    else if (c === sep) { linha.push(campo); campo = ''; }
    else if (c === '\n') { linha.push(campo); linhas.push(linha); linha = []; campo = ''; }
    else campo += c;
  }
  if (campo || linha.length) { linha.push(campo); linhas.push(linha); }
  return linhas;
}

/** As linhas e células do ficheiro (.xlsx ou .csv). */
export async function lerFolha(f: File): Promise<string[][]> {
  const b = new Uint8Array(await f.arrayBuffer());
  return b[0] === 0x50 && b[1] === 0x4b ? lerXlsx(b) : lerCsv(descodificar(b));
}
