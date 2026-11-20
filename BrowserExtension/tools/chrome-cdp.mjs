// Development only: shared pieces of the real-browser checks. Browser discovery (the one place every tool finds
// Chrome and Firefox), a disposable headless Chrome over --remote-debugging-pipe, a throwaway certificate, the
// test/pages server, and the trusted CDP input and closed-shadow-root lookups that drive the key button and its menu.
import { spawn, execFileSync } from 'node:child_process';
import { accessSync, constants, readdirSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, basename, delimiter, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const root = fileURLToPath(new URL('..', import.meta.url));
export const sleep = ms => new Promise(done => setTimeout(done, ms));

// Chromium-family browsers the real-browser end-to-end test may drive, in search order.
const browserApps = [
  ['Google Chrome', 'Google Chrome'], ['Google Chrome for Testing', 'Google Chrome for Testing'], ['Chromium', 'Chromium'],
  ['Google Chrome Beta', 'Google Chrome Beta'], ['Google Chrome Canary', 'Google Chrome Canary'], ['Microsoft Edge', 'Microsoft Edge'], ['Brave Browser', 'Brave Browser']
];
// Where `npx @puppeteer/browsers install chrome@stable --path <folder>` puts Chrome for Testing.
export const browserCacheFolders = home => [join(home, 'Library/Caches/KeeForge-E2E'), join(home, '.cache/puppeteer')];

// Searched last, in each `path` folder (Linux and other non-macOS systems).
const browserCommands = ['google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser'];

// An explicit choice is used as given and never falls back, so a wrong path fails instead of testing another browser.
// `fs` supplies `isExecutable(path)` and `list(dir)` (names, empty when missing); `path` lists command folders.
export function findBrowser({ explicit, home, fs, path = [] }) {
  if (explicit) return { browser: fs.isExecutable(explicit) ? explicit : null, searched: [explicit] };
  const searched = [];
  const found = path => { searched.push(path); return fs.isExecutable(path); };
  for (const folder of ['/Applications', join(home, 'Applications')]) {
    for (const [app, binary] of browserApps) {
      const path = join(folder, `${app}.app/Contents/MacOS/${binary}`);
      if (found(path)) return { browser: path, searched };
    }
  }
  for (const cache of browserCacheFolders(home)) {
    const versions = fs.list(join(cache, 'chrome')).sort().reverse();
    if (!versions.length) searched.push(join(cache, 'chrome/<version>/chrome-mac-*/Google Chrome for Testing.app'));
    for (const version of versions) {
      for (const platform of fs.list(join(cache, 'chrome', version)).filter(name => name.startsWith('chrome-mac'))) {
        const path = join(cache, 'chrome', version, platform, 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
        if (found(path)) return { browser: path, searched };
      }
    }
  }
  for (const folder of path) for (const command of browserCommands) if (found(join(folder, command))) return { browser: join(folder, command), searched };
  return { browser: null, searched };
}

// Firefox for firefox-check.mjs, with the same never-fall-back rule for an explicit path.
export function findFirefox({ explicit, home, fs, path = [] }) {
  const candidates = explicit ? [explicit] : [...['/Applications', join(home, 'Applications')].map(folder => join(folder, 'Firefox.app/Contents/MacOS/firefox')), ...path.map(folder => join(folder, 'firefox'))];
  return { browser: candidates.find(candidate => fs.isExecutable(candidate)) ?? null, searched: candidates };
}

export const localFs = {
  isExecutable: path => { try { accessSync(path, constants.X_OK); return statSync(path).isFile(); } catch { return false; } },
  list: dir => { try { return readdirSync(dir); } catch { return []; } }
};
// The development checks: $CHROME / $FIREFOX when set (used as given), else the search above. The Mac UI test's
// driver, e2e-browser.mjs, takes --browser or $KEEFORGE_E2E_BROWSER instead.
const local = (find, explicit, name, variable) => {
  const { browser, searched } = find({ explicit, home: homedir(), fs: localFs, path: (process.env.PATH || '').split(delimiter).filter(Boolean) });
  if (!browser) throw Error(`${name} was not found (set ${variable}); searched ${searched.join(', ')}`);
  return browser;
};
export const chromePath = () => local(findBrowser, process.env.CHROME, 'A Chromium-family browser', 'CHROME');
export const firefoxPath = () => local(findFirefox, process.env.FIREFOX, 'Firefox', 'FIREFOX');
// The checks load the source tree by default; CI points EXTENSION_DIR at build/chrome or build/firefox, the shipped files.
export const extensionDir = (base, fallback = '.') => resolve(process.env.EXTENSION_DIR || resolve(base, fallback));

// Self-signed, one day, for the given DNS names and 127.0.0.1. `spki` is the base64 SHA-256 of the
// public key, the form --ignore-certificate-errors-spki-list takes.
export async function makeCertificate(dir, names) {
  const keyPath = join(dir, 'key.pem'), certPath = join(dir, 'cert.pem');
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', `/CN=${names[0]}`, '-addext', `subjectAltName=${names.map(n => 'DNS:' + n).join(',')},IP:127.0.0.1`], { stdio: 'ignore' });
  const der = execFileSync('/usr/bin/openssl', ['pkey', '-in', keyPath, '-pubout', '-outform', 'DER']);
  return { key: await readFile(keyPath), cert: await readFile(certPath), spki: createHash('sha256').update(der).digest('base64') };
}

// Serves test/pages by file name only.
export const pagesHandler = async (request, response) => {
  try {
    const body = await readFile(join(root, 'test/pages', basename(new URL(request.url, 'http://localhost').pathname)));
    response.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' }); response.end(body);
  } catch { response.writeHead(404); response.end(); }
};
export const listen = (server, host, port = 0) => new Promise(done => { server.once('error', done); server.listen(port, host, done); });

export const chromeArgs = profile => [
  '--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--enable-unsafe-extension-debugging', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--use-mock-keychain', '--password-store=basic'
];

// Starts Chrome with the debugging pipe on fds 3/4. Every pending call is rejected once Chrome exits.
export function startChrome(executable, args, { env } = {}) {
  const child = spawn(executable, [...args, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], ...(env ? { env } : {}) });
  let stderr = '', buffer = '', nextId = 0, exitInfo = null;
  const pending = new Map();
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8000); });
  child.stdio[3].on('error', () => {});
  child.stdio[4].on('data', chunk => {
    buffer += chunk;
    for (let end; (end = buffer.indexOf('\0')) >= 0;) {
      const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      const waiter = message.id && pending.get(message.id);
      if (waiter) { clearTimeout(waiter.timer); pending.delete(message.id); message.error ? waiter.reject(Error(waiter.method + ': ' + message.error.message)) : waiter.resolve(message.result); }
    }
  });
  const exited = new Promise(resolve => {
    const failed = error => { exitInfo = error; for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(error); } pending.clear(); resolve(); };
    child.once('error', failed);
    child.once('exit', (code, signal) => failed(Error(`Chrome exited (${signal || code})`)));
  });
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    if (exitInfo) { reject(exitInfo); return; }
    const id = ++nextId, timer = setTimeout(() => { pending.delete(id); reject(Error('timeout: ' + method)); }, 15000);
    pending.set(id, { resolve, reject, method, timer });
    child.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  });
  const stop = async () => {
    if (!exitInfo) child.kill('SIGTERM');
    let timer;
    await Promise.race([exited, new Promise(done => { timer = setTimeout(() => { child.kill('SIGKILL'); done(); }, 3000); })]);
    clearTimeout(timer);
  };
  return { child, send, stop, exited, stderr: () => stderr };
}

// Page, menu and shadow-root helpers over one Chrome connection. `onAttach(sessionId)` runs for every attached target.
export function pageTools(send, { onAttach = async () => {} } = {}) {
  async function evaluate(session, expression) {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, session);
    if (r.exceptionDetails) throw Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  }
  async function waitFor(fn, label, tries = 80) {
    let value;
    for (let i = 0; i < tries; i++) { try { value = await fn(); if (value) return value; } catch (error) { value = error.message; } await sleep(100); }
    throw Error('timeout waiting for ' + label + ': ' + JSON.stringify(value));
  }
  async function attach(targetId) {
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    await send('Runtime.enable', {}, sessionId); await onAttach(sessionId);
    return sessionId;
  }
  async function tab(url) {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const session = await attach(targetId);
    await send('Page.enable', {}, session); await send('DOM.enable', {}, session);
    await send('Emulation.setFocusEmulationEnabled', { enabled: true }, session);
    await send('Page.navigate', { url }, session);
    await waitFor(() => evaluate(session, `document.readyState === 'complete' && location.href === ${JSON.stringify(url)}`), url);
    await sleep(700);
    return { session, targetId };
  }
  async function click(session, x, y) {
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, session);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }, session);
  }
  async function key(session, keyName, code = keyName) {
    for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: keyName, code, windowsVirtualKeyCode: { Enter: 13, Escape: 27 }[keyName] }, session);
  }
  async function nodes(session) {
    const tree = await send('DOM.getDocument', { depth: -1, pierce: true }, session);
    const found = [];
    (function walk(node, shadow) { found.push({ ...node, shadow }); for (const child of node.children || []) walk(child, shadow); for (const root of node.shadowRoots || []) walk(root, root.shadowRootType); })(tree.root, null);
    return found;
  }
  // Our UI is the only closed shadow root on these fixtures; boxes are in viewport CSS pixels.
  async function ui(session, name) {
    const boxes = [];
    for (const node of (await nodes(session)).filter(n => n.nodeName === name && n.shadow === 'closed')) {
      try { const q = (await send('DOM.getBoxModel', { backendNodeId: node.backendNodeId }, session)).model.border; boxes.push({ id: node.backendNodeId, left: q[0], top: q[1], right: q[2], bottom: q[5] }); }
      catch { boxes.push({ id: node.backendNodeId, hidden: true }); }
    }
    return boxes;
  }
  const visibleButtons = async session => (await ui(session, 'BUTTON')).filter(b => !b.hidden);
  const rect = (session, selector) => evaluate(session, `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom }; })()`);
  const buttonFor = async (session, selector) => { const r = await rect(session, selector); return (await visibleButtons(session)).find(b => b.top >= r.top && b.bottom <= r.bottom && b.left >= r.left && b.right <= r.right); };
  const menus = async () => (await send('Target.getTargets')).targetInfos.filter(t => t.type === 'iframe' && t.url.includes('/inline.html'));
  async function openMenu(page, selector) {
    const before = new Set((await menus()).map(t => t.targetId));
    const b = await waitFor(() => buttonFor(page.session, selector), 'button for ' + selector);
    await click(page.session, (b.left + b.right) / 2, (b.top + b.bottom) / 2);
    const target = await waitFor(async () => (await menus()).find(t => !before.has(t.targetId)), 'menu for ' + selector);
    return attach(target.targetId);
  }
  const text = session => evaluate(session, 'document.body.innerText');
  async function menuClick(page, menu, selector) {
    const [frame] = await ui(page.session, 'IFRAME');
    const point = await evaluate(menu, `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    await click(page.session, frame.left + point[0], frame.top + point[1]);
  }
  // Positive actions retry: a click inside the visibility window is refused by design. Returns the clicks needed.
  async function menuAct(page, menu, selector, done, label, report = console.log) {
    for (let attempt = 1; attempt <= 4; ++attempt) {
      await menuClick(page, menu, selector);
      for (let i = 0; i < 15; ++i) { if (await done().catch(() => false)) { if (attempt > 1) report(`  note: ${label} needed ${attempt} clicks`); return attempt; } await sleep(100); }
    }
    throw Error('menu action had no effect: ' + label);
  }
  const values = session => evaluate(session, `Object.fromEntries([...document.querySelectorAll('input')].map(i => [i.id, i.value]))`);
  return { evaluate, waitFor, attach, tab, click, key, nodes, ui, visibleButtons, rect, buttonFor, menus, openMenu, text, menuClick, menuAct, values };
}
