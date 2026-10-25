import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {senhaComprometida} from '../lib/password-leak.ts';

const SENHA = 'uma-palavra-passe-de-teste';
const IMPRESSAO = createHash('sha1').update(SENHA, 'utf8').digest('hex').toUpperCase();
const PREFIXO = IMPRESSAO.slice(0, 5);
const SUFIXO = IMPRESSAO.slice(5);

/** Substitui o fetch global e devolve o que foi pedido. */
function comResposta(corpo, {estado = 200, falhar = false} = {}) {
  const pedidos = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, opcoes) => {
    pedidos.push({url: String(url), opcoes});
    if (falhar) throw new Error('rede indisponivel');
    return new Response(corpo, {status: estado});
  };
  return {pedidos, repor: () => { globalThis.fetch = original; }};
}

test('recusa uma palavra-passe que aparece na lista de fugas', async () => {
  const espiao = comResposta(`0000000000000000000000000000000000:3\n${SUFIXO}:42\n`);
  try {
    assert.equal(await senhaComprometida(SENHA), true);
  } finally { espiao.repor(); }
});

test('o enchimento da resposta nao e confundido com uma fuga real', async () => {
  // O serviço devolve entradas falsas com contagem 0 para esconder o tamanho.
  const espiao = comResposta(`${SUFIXO}:0\n`);
  try {
    assert.equal(await senhaComprometida(SENHA), false);
  } finally { espiao.repor(); }
});

test('aceita uma palavra-passe que nao consta da lista', async () => {
  const espiao = comResposta('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:9\n');
  try {
    assert.equal(await senhaComprometida(SENHA), false);
  } finally { espiao.repor(); }
});

test('so os cinco primeiros caracteres do resumo saem daqui', async () => {
  const espiao = comResposta('');
  try {
    await senhaComprometida(SENHA);
    assert.equal(espiao.pedidos.length, 1);
    const {url, opcoes} = espiao.pedidos[0];
    assert.equal(url, `https://api.pwnedpasswords.com/range/${PREFIXO}`);
    assert.ok(!url.includes(SUFIXO), 'o sufixo do resumo nao pode sair');
    assert.ok(!url.includes(SENHA), 'a palavra-passe nao pode sair');
    assert.equal(opcoes.headers['Add-Padding'], 'true');
  } finally { espiao.repor(); }
});

test('se o servico falhar, nao se tranca ninguem a porta', async () => {
  const comErro = comResposta('', {falhar: true});
  try {
    assert.equal(await senhaComprometida(SENHA), false);
  } finally { comErro.repor(); }

  const comEstadoMau = comResposta('', {estado: 503});
  try {
    assert.equal(await senhaComprometida(SENHA), false);
  } finally { comEstadoMau.repor(); }
});
