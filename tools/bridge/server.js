// Local bridge between the desktop and a phone plugged in over USB.
//
// The phone exposes its browser debugging protocol over the cable: Chrome for
// Android through an abstract unix socket reachable via adb, Safari on iOS
// through ios_webkit_debug_proxy. In both cases we forward it to a local TCP
// port, list the inspectable pages, and evaluate the very same collector that
// the bookmarklet and the extension use.
//
// Nothing is installed on the phone and nothing is written: only reads.
import { execFile, spawn } from 'node:child_process';
import { createReadStream, existsSync, readdirSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const WEB_ROOT = join(ROOT, 'bridge');
const COLLECTOR_PATH = join(ROOT, 'dist', 'extension', 'injected.js');

const PORT = Number(process.env.PORT || 8770);
// Android forwards start at 9222, one port per debugging socket on the phone.
// The iOS proxy defaults to 9221 for its device list and 9222 upwards for the
// devices themselves, which collides with those forwards and makes iOS requests
// land on the Android tunnel, so it is moved well clear of them.
const ANDROID_PORT = 9222;
const IOS_PROXY_PORT = 9331;
const IOS_DEVICE_PORTS = `${IOS_PROXY_PORT + 1}-${IOS_PROXY_PORT + 101}`;

// The report is fetched by polling a global rather than with the protocol's own
// promise support: WebKit and Chrome disagree on awaitPromise, but both agree on
// plain synchronous evaluation.
const COLLECT_SNIPPET = `
(function () {
  var slot = "__airshipBridgeReport";
  if (window[slot] && window[slot].pending) return "pending";
  if (window[slot] && window[slot].done) { var out = window[slot].value; window[slot] = null; return out; }
  window[slot] = { pending: true };
  try {
    Promise.resolve(window.__airshipWebSdkInspector.collect()).then(
      function (report) { window[slot] = { done: true, value: JSON.stringify({ ok: true, report: report }) }; },
      function (error) { window[slot] = { done: true, value: JSON.stringify({ ok: false, error: String(error) }) }; }
    );
  } catch (error) {
    window[slot] = { done: true, value: JSON.stringify({ ok: false, error: String(error) }) };
  }
  return "pending";
})()
`;

function run(command, args, { timeout = 15000 } = {}) {
  return new Promise((resolve) => {
    execFile(command, args, { timeout, encoding: 'utf8' }, (error, stdout, stderr) => {
      resolve({ ok: !error, stdout: stdout || '', stderr: stderr || '', error: error ? error.message : null });
    });
  });
}

async function which(binary) {
  const { ok, stdout } = await run('/usr/bin/which', [binary], { timeout: 4000 });
  return ok ? stdout.trim() : null;
}

async function fetchJson(url, timeout = 6000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    // Chrome answers /json with the right content type; the iOS proxy is looser.
    return JSON.parse(await response.text());
  } finally {
    clearTimeout(timer);
  }
}

// --- Android ---------------------------------------------------------------

async function androidDevices() {
  const adb = await which('adb');
  if (!adb) return { available: false, reason: 'adb is not installed', devices: [] };

  const { ok, stdout, stderr } = await run(adb, ['devices', '-l']);
  if (!ok) return { available: true, reason: stderr.trim() || 'adb failed', devices: [] };

  const devices = stdout
    .split('\n')
    .slice(1)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [serial, state] = line.split(/\s+/);
      const model = /model:(\S+)/.exec(line);
      return { serial, state, model: model ? model[1].replace(/_/g, ' ') : null };
    })
    .filter((device) => device.serial && device.serial !== 'List');

  return { available: true, reason: null, devices };
}

// A phone can expose several debugging sockets at once: Chrome, another browser,
// and one per WebView. Reading /proc/net/unix is the only reliable enumeration.
async function androidSockets(serial) {
  const adb = await which('adb');
  const { stdout } = await run(adb, ['-s', serial, 'shell', 'cat', '/proc/net/unix']);
  const sockets = new Set();

  for (const line of stdout.split('\n')) {
    const match = /@(\S*devtools_remote\S*)/.exec(line);
    if (match) sockets.add(match[1]);
  }

  return Array.from(sockets);
}

async function androidForward(serial, socket, port) {
  const adb = await which('adb');
  // remove first, so repeated runs do not stack forwards on the same port
  await run(adb, ['-s', serial, 'forward', '--remove', `tcp:${port}`]);
  const { ok, stderr } = await run(adb, ['-s', serial, 'forward', `tcp:${port}`, `localabstract:${socket}`]);
  if (!ok) throw new Error(`adb forward failed: ${stderr.trim()}`);
}

// A locked or dozing phone keeps its debugging socket open while the browser
// stops answering, which otherwise surfaces as a bare timeout. Ask the phone
// what state it is in so the page can say what to do about it.
async function androidHints(serial) {
  const adb = await which('adb');
  const hints = [];

  const power = await run(adb, ['-s', serial, 'shell', 'dumpsys', 'power']);
  const locked = await run(adb, ['-s', serial, 'shell', 'dumpsys', 'window']);
  if (/mWakefulness=(Dozing|Asleep)/i.test(power.stdout) || /mDreamingLockscreen=true/.test(locked.stdout)) {
    hints.push('the phone screen is off or locked — wake it up and unlock it');
  }

  const activities = await run(adb, ['-s', serial, 'shell', 'dumpsys', 'activity', 'activities']);
  const resumed = /ResumedActivity:[^\n]*?\bu\d+\s+([\w.]+)\//.exec(activities.stdout);
  if (resumed && !/chrome/i.test(resumed[1])) {
    hints.push(`Chrome is not in the foreground (${resumed[1]} is) — open Chrome on the customer page`);
  }

  return hints;
}

async function androidTargets(serial) {
  const allSockets = await androidSockets(serial);
  // stetho_* sockets belong to instrumented apps, not to a browser, and never
  // answer the browser protocol.
  const sockets = allSockets.filter((socket) => !socket.startsWith('stetho_'));

  if (!sockets.length) {
    throw new Error(
      'No browser debugging socket on the phone. Enable Developer options, then USB debugging, then open Chrome on the phone.'
    );
  }

  const targets = [];
  let port = ANDROID_PORT;

  for (const socket of sockets) {
    try {
      await androidForward(serial, socket, port);
      const list = await fetchJson(`http://127.0.0.1:${port}/json/list`);
      for (const page of list) {
        if (page.type && page.type !== 'page') continue;
        targets.push({
          platform: 'android',
          socket,
          id: page.id,
          title: page.title,
          url: page.url,
          ws: page.webSocketDebuggerUrl
        });
      }
    } catch (error) {
      targets.push({ platform: 'android', socket, error: String(error.message || error) });
    }
    port += 1;
  }

  if (!targets.some((target) => target.ws)) {
    const hints = await androidHints(serial);
    throw new Error(
      hints.length
        ? `The phone is not answering: ${hints.join(', and ')}. Then scan again.`
        : 'The phone is not answering on its debugging socket. Open Chrome on the customer page, then scan again.'
    );
  }

  return targets;
}

// --- iOS -------------------------------------------------------------------

let iosProxy = null;
let iosVersion = null;

// Asking libimobiledevice directly means the phone is named in the status line
// before any proxy is started.
async function iosProbe() {
  const proxy = await which('ios_webkit_debug_proxy');
  const list = await which('idevice_id');
  const info = await which('ideviceinfo');

  const probe = { proxyInstalled: Boolean(proxy), device: null, version: null };

  if (list) {
    const { stdout } = await run(list, ['-l'], { timeout: 6000 });
    const udid = stdout.trim().split('\n')[0];
    if (udid && info) {
      const name = await run(info, ['-k', 'DeviceName'], { timeout: 6000 });
      const version = await run(info, ['-k', 'ProductVersion'], { timeout: 6000 });
      probe.device = name.stdout.trim() || udid;
      probe.version = version.stdout.trim() || null;
      if (probe.version) iosVersion = probe.version;
    }
  }

  return probe;
}

async function iosStartProxy() {
  if (iosProxy && !iosProxy.killed) return;

  const binary = await which('ios_webkit_debug_proxy');
  if (!binary) throw new Error('ios_webkit_debug_proxy is not installed (brew install ios-webkit-debug-proxy)');

  // --no-frontend: we only need the protocol, not the bundled DevTools UI, and
  // the proxy binds every interface with no option to restrict it.
  iosProxy = spawn(binary, ['--no-frontend', '-c', `null:${IOS_PROXY_PORT},:${IOS_DEVICE_PORTS}`], {
    stdio: ['ignore', 'pipe', 'pipe']
  });
  iosProxy.stdout.setEncoding('utf8');
  iosProxy.stderr.setEncoding('utf8');
  iosProxy.stdout.on('data', (chunk) => process.stdout.write(`[ios-proxy] ${chunk}`));
  iosProxy.stderr.on('data', (chunk) => process.stdout.write(`[ios-proxy] ${chunk}`));
  iosProxy.on('exit', () => {
    iosProxy = null;
  });

  // Give the proxy a moment to bind before the first request.
  await new Promise((resolve) => setTimeout(resolve, 900));
}

async function iosTargets() {
  await iosStartProxy();

  const devices = await fetchJson(`http://127.0.0.1:${IOS_PROXY_PORT}/json`);
  const targets = [];

  if (devices.length) iosVersion = devices[0].deviceOSVersion || null;

  for (const device of devices) {
    // The proxy publishes one port per device, in the "host:port" it reports.
    const port = /:(\d+)$/.exec(device.url || '');
    if (!port) continue;

    try {
      const pages = await fetchJson(`http://127.0.0.1:${port[1]}/json`);
      for (const page of pages) {
        // A service worker target has no window to inspect, so it can never
        // answer the collector.
        if (page.title === 'ServiceWorker') continue;
        targets.push({
          platform: 'ios',
          device: device.deviceName || device.deviceId,
          title: page.title,
          url: page.url,
          ws: page.webSocketDebuggerUrl
        });
      }
    } catch (error) {
      targets.push({ platform: 'ios', device: device.deviceName, error: String(error.message || error) });
    }
  }

  if (!targets.length) {
    throw new Error(
      'No inspectable page. On the iPhone: Settings > Safari > Advanced > Web Inspector, then open the site in Safari and trust this computer.'
    );
  }

  return targets;
}

// --- Manual endpoint -------------------------------------------------------

// Escape hatch for anything already exposing the protocol on a TCP port: an
// Android phone paired over Wi-Fi with `adb tcpip`, a browser started with
// --remote-debugging-port, or a forward set up by hand.
async function manualTargets(endpoint) {
  let base;
  try {
    base = new URL(endpoint);
  } catch (error) {
    throw new Error('invalid endpoint, expected something like http://127.0.0.1:9222');
  }
  if (!/^https?:$/.test(base.protocol)) throw new Error('the endpoint must be http or https');

  const list = await fetchJson(new URL('/json/list', base).toString());

  return list
    .filter((page) => !page.type || page.type === 'page')
    .map((page) => ({
      platform: 'manual',
      id: page.id,
      title: page.title,
      url: page.url,
      ws: page.webSocketDebuggerUrl
    }));
}

// --- Debugging protocol ----------------------------------------------------

// Minimal client: connect, send commands, resolve by id. Enough for what we do,
// and it keeps the tool dependency-free (Node ships a WebSocket client).
function connect(wsUrl, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const pending = new Map();
    const targets = [];
    let pageTargetWaiter = null;
    let nextId = 1;

    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`connection to ${wsUrl} timed out`));
    }, timeout);

    socket.addEventListener('open', () => {
      clearTimeout(timer);
      resolve({
        send(method, params = {}) {
          const id = nextId++;
          socket.send(JSON.stringify({ id, method, params }));
          return new Promise((ok, ko) => {
            const commandTimer = setTimeout(() => {
              pending.delete(id);
              ko(new Error(`${method} timed out`));
            }, timeout);
            pending.set(id, { ok, ko, commandTimer });
          });
        },

        // Same command, addressed to one target instead of to the connection.
        // The answer arrives as a Target.dispatchMessageFromTarget event whose
        // payload carries the inner id, so that is the id waited on here.
        sendVia(targetId, method, params = {}) {
          const inner = { id: nextId++, method, params };
          socket.send(
            JSON.stringify({
              id: nextId++,
              method: 'Target.sendMessageToTarget',
              params: { targetId, message: JSON.stringify(inner) }
            })
          );
          return new Promise((ok, ko) => {
            const commandTimer = setTimeout(() => {
              pending.delete(inner.id);
              ko(new Error(`${method} timed out`));
            }, timeout);
            pending.set(inner.id, { ok, ko, commandTimer });
          });
        },

        // Targets announce themselves as soon as the connection opens, so this
        // is a short wait rather than a request. Null means the phone announced
        // none, which is the older behaviour.
        pageTarget(wait = 2000) {
          const known = targets.find((target) => target.type === 'page');
          if (known) return Promise.resolve(known.targetId);
          return new Promise((done) => {
            const timer = setTimeout(() => {
              pageTargetWaiter = null;
              done(null);
            }, wait);
            pageTargetWaiter = (target) => {
              clearTimeout(timer);
              pageTargetWaiter = null;
              done(target.targetId);
            };
          });
        },
        close() {
          try {
            socket.close();
          } catch (error) {
            /* already closed */
          }
        }
      });
    });

    socket.addEventListener('message', (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch (error) {
        return;
      }

      if (message.method === 'Target.targetCreated') {
        const target = message.params && message.params.targetInfo;
        if (target) {
          targets.push(target);
          if (target.type === 'page' && pageTargetWaiter) pageTargetWaiter(target);
        }
        return;
      }

      // A reply from a target is an event wrapping the real reply.
      if (message.method === 'Target.dispatchMessageFromTarget') {
        try {
          message = JSON.parse(message.params.message);
        } catch (error) {
          return;
        }
      }

      const waiter = message.id != null && pending.get(message.id);
      if (!waiter) return;
      clearTimeout(waiter.commandTimer);
      pending.delete(message.id);
      if (message.error) waiter.ko(new Error(message.error.message || JSON.stringify(message.error)));
      else waiter.ok(message.result);
    });

    socket.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new Error(`cannot reach ${wsUrl}`));
    });

    socket.addEventListener('close', () => {
      for (const waiter of pending.values()) {
        clearTimeout(waiter.commandTimer);
        waiter.ko(new Error('debugging connection closed'));
      }
      pending.clear();
    });
  });
}

function readCollector() {
  if (!existsSync(COLLECTOR_PATH)) {
    throw new Error('dist/extension/injected.js is missing — run npm run build first');
  }
  return readFileSync(COLLECTOR_PATH, 'utf8');
}

async function evaluate(call, expression) {
  const result = await call('Runtime.evaluate', {
    expression,
    returnByValue: true,
    includeCommandLineAPI: false,
    // WebKit ignores unknown parameters, Chrome uses this one.
    replMode: false
  });

  if (result.exceptionDetails) {
    const text = result.exceptionDetails.text || '';
    const nested = result.exceptionDetails.exception?.description || '';
    throw new Error(`evaluation failed on the phone: ${nested || text}`);
  }

  // Chrome returns { result: { value } }, WebKit the same shape for primitives.
  return result.result ? result.result.value : undefined;
}

async function collectFromTarget(wsUrl, platform) {
  const session = await connect(wsUrl);
  try {
    // From iOS 26, WebKit Site Isolation answers Runtime calls on the page
    // target rather than on the page connection: sent to the connection they
    // come back as "'Runtime' domain was not found". So on an iPhone the
    // commands travel to whichever page target the phone announces. Android
    // announces none and answers on the connection, as older iOS does.
    const target = platform === 'ios' ? await session.pageTarget() : null;
    const call = target
      ? (method, params) => session.sendVia(target, method, params)
      : (method, params) => session.send(method, params);

    // Android freezes background tabs: their timers and promises never progress,
    // so the collector would start and never finish. Activating the tab first is
    // what makes a remote read reliable.
    await call('Page.bringToFront').catch(() => {});
    await call('Runtime.enable').catch(() => {});
    await evaluate(call, readCollector());

    // First call starts the collection, later ones pick up the result. An iPhone
    // that is going to answer does so quickly, so it gets a shorter budget.
    const attempts = platform === 'ios' ? 32 : 100;

    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const value = await evaluate(call, COLLECT_SNIPPET);
      if (typeof value === 'string' && value !== 'pending') {
        const parsed = JSON.parse(value);
        if (!parsed.ok) throw new Error(parsed.error);
        return parsed.report;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    throw new Error(
      platform === 'ios'
        ? 'the iPhone accepted the connection but returned no report within 8 seconds — keep it unlocked with that page open, then read again'
        : 'the phone did not return a report within 25 seconds — keep the phone unlocked with that tab visible, then read again'
    );
  } finally {
    session.close();
  }
}

// --- HTTP ------------------------------------------------------------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  // Chrome ignores a manifest served as anything else, and the page then stops
  // being installable.
  '.webmanifest': 'application/manifest+json; charset=utf-8'
};

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store'
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', (chunk) => {
      chunks.push(chunk);
      if (chunks.reduce((n, c) => n + c.length, 0) > 1e6) reject(new Error('body too large'));
    });
    request.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on('error', reject);
  });
}

function serveStatic(request, response) {
  const requested = new URL(request.url, 'http://localhost').pathname;
  const relative = requested === '/' ? 'index.html' : requested.slice(1);
  const path = join(WEB_ROOT, normalize(relative));

  // normalize() plus this guard keeps the server inside bridge/.
  if (!path.startsWith(WEB_ROOT) || !existsSync(path)) {
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('not found');
    return;
  }

  response.writeHead(200, {
    'content-type': MIME[extname(path)] || 'application/octet-stream',
    'cache-control': 'no-store'
  });
  createReadStream(path).pipe(response);
}

const server = createServer(async (request, response) => {
  const { pathname } = new URL(request.url, 'http://localhost');

  try {
    if (pathname === '/api/status') {
      const android = await androidDevices();
      const ios = await iosProbe();

      return sendJson(response, 200, {
        collectorReady: existsSync(COLLECTOR_PATH),
        // Only the launcher can bring the server back, so only a server it
        // started may offer the button that stops one.
        canRestart: process.env.BRIDGE_MANAGED === '1',
        android,
        ios: {
          available: ios.proxyInstalled,
          device: ios.device,
          version: ios.version,
          reason: !ios.proxyInstalled
            ? 'ios_webkit_debug_proxy is not installed (brew install ios-webkit-debug-proxy)'
            : ios.device
              ? `${ios.device}, iOS ${ios.version}`
              : 'no iPhone detected',
          proxyRunning: Boolean(iosProxy && !iosProxy.killed)
        }
      });
    }

    if (pathname === '/api/targets') {
      const query = new URL(request.url, 'http://localhost').searchParams;
      const platform = query.get('platform');

      const targets =
        platform === 'ios'
          ? await iosTargets()
          : platform === 'manual'
            ? await manualTargets(query.get('endpoint'))
            : await androidTargets(query.get('serial'));

      return sendJson(response, 200, { targets });
    }

    // Updating means replacing the very files this process is running, so the
    // process cannot do it to itself. It steps aside with exit code 75 instead,
    // which the launcher reads as "update and start over".
    if (pathname === '/api/restart' && request.method === 'POST') {
      if (process.env.BRIDGE_MANAGED !== '1') {
        throw new Error(
          'this bridge was not started by the launcher, so nothing would bring it back — restart it the way you started it'
        );
      }
      response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
      return response.end(JSON.stringify({ ok: true }), () => {
        if (iosProxy && !iosProxy.killed) iosProxy.kill();
        // A page held open on a keep-alive connection would keep close()
        // waiting, so the timer is the one that has the last word.
        server.close(() => process.exit(75));
        setTimeout(() => process.exit(75), 1500).unref();
      });
    }

    if (pathname === '/api/collect' && request.method === 'POST') {
      const { ws, platform } = await readBody(request);
      if (typeof ws !== 'string' || !/^wss?:\/\//.test(ws)) throw new Error('invalid target');
      return sendJson(response, 200, { report: await collectFromTarget(ws, platform) });
    }

    return serveStatic(request, response);
  } catch (error) {
    return sendJson(response, 500, { error: String(error.message || error) });
  }
});

// Opening the page is half of starting the bridge, so the server does it. Set
// BRIDGE_OPEN=0 to keep the terminal to itself — when restarting the server
// repeatedly, or when the app is already installed and open.
// Chrome installs a web app as a real .app on macOS. Opening that rather than
// the URL is what makes the installed icon worth having: one double-click on the
// launcher then starts the server and brings up the app window, instead of a tab
// among the twenty already open.
function installedMacApp() {
  if (process.platform !== 'darwin') return null;

  const parents = [
    join(homedir(), 'Applications'),
    join(homedir(), 'Applications', 'Chrome Apps.localized'),
    join(homedir(), 'Applications', 'Chrome Apps')
  ];

  for (const parent of parents) {
    if (!existsSync(parent)) continue;
    const match = readdirSync(parent).find((name) => /usb bridge.*\.app$/i.test(name));
    if (match) return join(parent, match);
  }

  return null;
}

function openInBrowser(url) {
  if (process.env.BRIDGE_OPEN === '0') return;

  const app = installedMacApp();
  if (app) {
    execFile('open', ['-a', app], (error) => {
      if (error) execFile('open', [url], () => {});
    });
    return;
  }

  const opener =
    process.platform === 'darwin'
      ? ['open', [url]]
      : process.platform === 'win32'
        ? ['cmd', ['/c', 'start', '', url]]
        : ['xdg-open', [url]];

  execFile(opener[0], opener[1], () => {
    /* no browser to open is not a reason to fail: the URL is printed above */
  });
}

server.listen(PORT, '127.0.0.1', () => {
  const url = `http://localhost:${PORT}`;
  console.log(`Airship Web SDK Inspector — USB bridge on ${url}`);
  if (!existsSync(COLLECTOR_PATH)) console.log('Warning: run `npm run build` first, the collector bundle is missing.');
  openInBrowser(url);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    if (iosProxy && !iosProxy.killed) iosProxy.kill();
    server.close(() => process.exit(0));
  });
}
