const CACHE_NAME = 'vshook-diretor-pwa-v98';
const APP_ASSETS = [
  '/',
  '/index.html',
  '/stylediretor.css',
  '/vsdiretor.js',
  '/vsdiretor.webmanifest',
  '/vsdiretor-icon-180.png',
  '/vsdiretor-icon-192.png',
  '/vsdiretor-icon-512.png',
  '/vsdiretor-icon-512-maskable.png',
  '/diretor.png'
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

  try {
    const url = new URL(req.url);
    const apiPaths = ['/discovery', '/discovery.json', '/projects', '/projects.json', '/state', '/state.json', '/command', '/technical-notice', '/recados-notice', '/health', '/ping', '/bridge-info'];
    if (apiPaths.includes(url.pathname)) return;
  } catch (error) {}

  event.respondWith(
    fetch(req).then((res) => {
      const copy = res.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(req, copy)).catch(() => null);
      return res;
    }).catch(() =>
      caches.match(req).then((cached) => cached || caches.match('/index.html'))
    )
  );
});
