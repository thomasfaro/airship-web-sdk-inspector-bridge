// Service worker of the bridge web app.
//
// It exists for two reasons. Chrome only offers to install a page that
// registers a worker with a fetch handler, and a worker is what lets the
// installed icon open onto something other than a browser error when the server
// behind it is not running.
//
// Network first, always: the server is on localhost and never slow, and the
// pages it serves are marked no-store precisely so a stale bundle is never
// shown. The cache is only ever read when the fetch fails, which here means one
// thing — the bridge is not started. The page then loads and says so.
const CACHE = 'airship-bridge-shell';
const SHELL = ['/', '/bridge.css', '/ui.js', '/favicon.png', '/icon192.png', '/icon512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  // The API is the live conversation with the phone. Serving a stale answer for
  // it would be worse than failing, and the page already handles the failure.
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;

  event.respondWith(networkFirst(request));
});

async function networkFirst(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(request, copy));
    }
    return response;
  } catch (error) {
    const cached = await caches.match(request, { ignoreSearch: true });
    if (cached) return cached;

    // A deep link, or a reload of the app window, with nothing cached under
    // that exact URL: the shell is the right answer, it knows how to explain
    // that the bridge is down.
    if (request.mode === 'navigate') {
      const shell = await caches.match('/');
      if (shell) return shell;
    }

    throw error;
  }
}
