/* Gestão de Clientes — service worker.
   Estratégia deliberadamente conservadora: a aplicação lida com dados fiscais,
   por isso nada de respostas autenticadas em cache. Guardamos apenas o que é
   estático e uma página de apoio para quando a rede falha. */

const VERSAO = 'rr-gestao-v2';
const ESTATICO = `${VERSAO}-estatico`;
const OFFLINE = '/offline';

const ESSENCIAIS = [OFFLINE, '/favicon.svg', '/icone-192.png', '/icone-512.png'];

self.addEventListener('install', (evento) => {
  evento.waitUntil(
    caches.open(ESTATICO).then((cache) => cache.addAll(ESSENCIAIS)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (evento) => {
  evento.waitUntil(
    caches
      .keys()
      .then((chaves) => Promise.all(chaves.filter((c) => !c.startsWith(VERSAO)).map((c) => caches.delete(c))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (evento) => {
  const pedido = evento.request;
  if (pedido.method !== 'GET') return;

  const url = new URL(pedido.url);
  if (url.origin !== self.location.origin) return;
  // Nunca guardar dados de sessão, API ou autenticação.
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/auth/')) return;

  // Recursos com impressão digital no nome: cache primeiro, são imutáveis.
  if (url.pathname.startsWith('/_next/static/') || ESSENCIAIS.includes(url.pathname)) {
    evento.respondWith(
      caches.match(pedido).then(
        (guardado) =>
          guardado ||
          fetch(pedido).then((resposta) => {
            if (resposta.ok) {
              const copia = resposta.clone();
              caches.open(ESTATICO).then((cache) => cache.put(pedido, copia));
            }
            return resposta;
          }),
      ),
    );
    return;
  }

  // Navegação: rede primeiro, página de apoio se não houver ligação.
  if (pedido.mode === 'navigate') {
    evento.respondWith(fetch(pedido).catch(() => caches.match(OFFLINE).then((r) => r || Response.error())));
  }
});
