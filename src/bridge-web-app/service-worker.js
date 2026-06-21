const CACHE_NAME = 'vshook-director-1.9.0-auto-front-dispositivos';
const APP_ASSETS = [
  './',
  './index.html',
  './app-shell.js',
  './stylediretor.css',
  './stylediretor-app.css',
  './vsdiretor.js',
  './vsdiretor.webmanifest',
  './musicos.html',
  './musicos.css',
  './musicos-app.css',
  './vsmusicos.js',
  './musicos.webmanifest',
  './recados.html',
  './recados.js',
  './recados-app.css',
  './recados.webmanifest',
  './vshook-diretor-play-single-command-block-name-20260620',
  './vshook-diretor-play-single-command-block-name-20260620',
  './vsdiretor-icon-180.png',
  './vsdiretor-icon-192.png',
  './vsdiretor-icon-512.png',
  './vsdiretor-icon-512-maskable.png',
  './vsmusicos-icon-180.png',
  './vsmusicos-icon-192.png',
  './vsmusicos-icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS)).catch(() => null)
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  const apiPaths = [
    '/discovery', '/discovery.json',
    '/projects', '/projects.json',
    '/state', '/state.json',
    '/lyrics', '/lyrics.json',
    '/command', '/technical-notice', '/recados-notice',
    '/health', '/ping', '/bridge-info', '/qr.svg', '/app-qr.svg'
  ];

  if (apiPaths.includes(url.pathname)) {
    event.respondWith(fetch(req));
    return;
  }

  event.respondWith(
    fetch(req).then((res) => {
      const copy = res.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(req, copy)).catch(() => null);
      return res;
    }).catch(() =>
      caches.match(req).then((cached) => {
        if (cached) return cached;
        if (req.mode === 'navigate') return caches.match('/index.html');
        return new Response('', { status: 504, statusText: 'Offline' });
      })
    )
  );
});
