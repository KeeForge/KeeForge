#!/usr/bin/env node
// Drives this extension in a real, disposable headless Chromium against a real native host: the browser half of
// KeeForgeMacUITests/MacBrowserExtensionUITests. One JSON command per stdin line, one JSON object per stdout line,
// like e2e-client.mjs, and started the same way (e2e-client-launcher.sh, outside the runner's sandbox).
// The native-host manifest goes only into the temporary profile's NativeMessagingHosts folder. The login page is
// test/pages/inline.html served over HTTPS as https://<domain> (default alpha.example.com, the fixture entry's site):
// Chrome maps that name to a loopback port and trusts only this run's throwaway certificate.
// Passwords never leave the driver: `fields` reports a password input's length and SHA-256.
// Exit codes: 0 after "quit" or stdin end, 2 bad arguments or host not executable.
import { spawn } from 'node:child_process';
import { accessSync, constants } from 'node:fs';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { createServer as createHttpsServer } from 'node:https';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { tmpdir, userInfo } from 'node:os';
import { join } from 'node:path';
import { root, sleep, findBrowser, localFs, makeCertificate, pagesHandler, listen, chromeArgs, startChrome, pageTools } from './chrome-cdp.mjs';

const args = process.argv.slice(2);
const option = name => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
const hostPath = option('--host'), domain = option('--domain') ?? 'alpha.example.com';
if (!hostPath) { process.stderr.write('usage: e2e-browser.mjs --host <path> [--browser <path>] [--domain <name>]\n'); process.exit(2); }
try { accessSync(hostPath, constants.X_OK); } catch { process.stderr.write(`host not executable: ${hostPath}\n`); process.exit(2); }

const emit = object => process.stdout.write(JSON.stringify(object) + '\n');
const account = userInfo();
// Only what a browser started from the Dock would pass on to the host it launches.
const browserEnvironment = {
  PATH: '/usr/bin:/bin:/usr/sbin:/sbin', HOME: account.homedir, USER: account.username, LOGNAME: account.username,
  SHELL: account.shell ?? '/bin/zsh', LANG: process.env.LANG ?? 'en_US.UTF-8'
};
const discovery = findBrowser({ explicit: option('--browser') || process.env.KEEFORGE_E2E_BROWSER, home: account.homedir, fs: localFs });
emit({ event: 'driver-ready', parentSandboxed: 'APP_SANDBOX_CONTAINER_ID' in process.env, browser: discovery.browser, searched: discovery.searched });

const EXTENSION_ID = 'pihelgeaeflnpjjdajbdmfmcpgeoefbf';
const origin = `https://${domain}`;
let profile, server, chrome, tools, page, menu, pair, worker, extension;

async function start() {
  if (!discovery.browser) throw Object.assign(Error(`browser-missing: no Chromium-family browser; searched ${discovery.searched.join(', ')}`), { code: 'browser-missing' });
  profile = await mkdtemp(join(tmpdir(), 'keeforge-e2e-browser-'));
  const tls = await makeCertificate(profile, [domain]);
  server = createHttpsServer(tls, pagesHandler);
  await listen(server, '127.0.0.1');
  const port = server.address().port;
  // Chrome reads per-user native hosts from <user-data-dir>/NativeMessagingHosts, so ~/Library is never touched.
  await mkdir(join(profile, 'NativeMessagingHosts'));
  const manifest = join(profile, 'NativeMessagingHosts/com.keevault.browser.json');
  await writeFile(manifest, JSON.stringify({ name: 'com.keevault.browser', description: 'KeeForge end-to-end test', path: hostPath, type: 'stdio', allowed_origins: [`chrome-extension://${EXTENSION_ID}/`] }));
  chrome = startChrome(discovery.browser, [...chromeArgs(profile),
    `--host-resolver-rules=MAP ${domain} 127.0.0.1:${port}, MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1`,
    `--ignore-certificate-errors-spki-list=${tls.spki}`, '--window-size=1100,760'], { env: browserEnvironment });
  tools = pageTools(chrome.send);
  const product = (await chrome.send('Browser.getVersion')).product;
  const { id } = await chrome.send('Extensions.loadUnpacked', { path: root });
  if (id !== EXTENSION_ID) throw Error(`unexpected extension id ${id}; the manifest key must give ${EXTENSION_ID}`);
  extension = `chrome-extension://${id}/`;
  const target = await tools.waitFor(async () => (await targets()).find(t => t.type === 'service_worker' && t.url.startsWith(extension)), 'service worker');
  worker = await tools.attach(target.targetId);
  return { product, extensionId: id, origin, port };
}

const targets = async () => (await chrome.send('Target.getTargets')).targetInfos;
const need = (value, what) => { if (!value) throw Error(`${what} first`); return value; };
const message = key => tools.evaluate(worker, `chrome.i18n.getMessage(${JSON.stringify(key)})`);

async function openLogin() {
  if (page) await chrome.send('Target.closeTarget', { targetId: page.targetId }).catch(() => {});
  menu = null;
  page = await tools.tab(`${origin}/inline.html`);
  const facts = await tools.evaluate(page.session, `({ url: location.href, origin: location.origin, secure: isSecureContext })`);
  const buttons = await tools.waitFor(async () => (await tools.visibleButtons(page.session)).length || 0, 'key buttons');
  return { ...facts, buttons };
}

const menuOpen = async () => !!menu && (await tools.menus()).some(t => t.targetId === menu.targetId);

async function clickKey({ field }) {
  need(page, 'openLogin');
  if (await menuOpen()) await closeMenu();
  const before = new Set((await tools.menus()).map(t => t.targetId));
  const session = await tools.openMenu(page, '#' + field);
  const target = (await tools.menus()).find(t => !before.has(t.targetId));
  menu = { session, targetId: target?.targetId, field };
  return { opened: true, field };
}

const GLYPH_STATES = { lock: 'locked', link: 'unpaired', power: 'app-unavailable', key: 'empty', alert: 'error', page: 'error' };
async function menuState() {
  if (!(await menuOpen())) return { open: false };
  const raw = await tools.evaluate(menu.session, `(() => {
    const icon = document.querySelector('#state-icon').className, stateHidden = document.querySelector('#state').hidden;
    const rows = [...document.querySelectorAll('.kf-row')].map(row => ({ title: row.querySelector('.kf-title')?.textContent ?? '', username: row.querySelector('.kf-username')?.textContent ?? '', code: !!row.querySelector('.kf-code') }));
    return { icon, stateHidden, rows, status: document.querySelector('#status').textContent, site: document.querySelector('#site').textContent,
      actions: [...document.querySelectorAll('#content > button')].map(b => b.textContent) };
  })()`);
  const glyph = raw.icon.match(/glyph-(\w+)/)?.[1];
  const state = raw.rows.length && raw.stateHidden ? 'logins' : raw.icon.includes('kf-waiting') ? 'loading' : GLYPH_STATES[glyph] ?? 'unknown';
  return { open: true, state, status: raw.status, site: raw.site, rows: raw.rows, actions: raw.actions };
}

async function waitMenu({ state, title, timeout = 15 }) {
  let last;
  for (const deadline = Date.now() + timeout * 1000; Date.now() < deadline; await sleep(200)) {
    last = await menuState();
    if (last.state === state && (!title || last.rows.some(row => row.title === title))) return last;
  }
  throw Error(`menu not ${state}${title ? ` with ${title}` : ''} within ${timeout} s: ${JSON.stringify(last)}`);
}

// A menu click within 300 ms of the menu becoming visible or re-rendering is refused by design, so let it settle.
const settle = () => sleep(1200);

async function menuPair() {
  need(menu, 'clickKey');
  await waitMenu({ state: 'unpaired' });
  await settle();
  const pairPage = async () => (await targets()).find(t => t.type === 'page' && t.url === extension + 'pair.html');
  const clicks = await tools.menuAct(page, menu.session, '#content .kf-primary', pairPage, 'Pair', note);
  pair = { targetId: (await pairPage()).targetId };
  pair.session = await tools.attach(pair.targetId);
  const shown = await tools.waitFor(() => tools.evaluate(pair.session, `(() => { const code = document.querySelector('#code').textContent; return /^\\d{3} \\d{3}$/.test(code) && { code, browser: document.querySelector('#browser').textContent }; })()`), 'pairing code', 200);
  // The pairing tab took the foreground; the menu keeps polling only while its page is visible.
  await chrome.send('Target.activateTarget', { targetId: page.targetId });
  return { code: shown.code.replace(' ', ''), browserLabel: shown.browser, clicks };
}

async function waitPaired({ timeout = 30 }) {
  const paired = await message('paired');
  let last;
  for (const deadline = Date.now() + timeout * 1000; Date.now() < deadline; await sleep(250)) {
    last = await tools.evaluate(need(pair, 'menuPair').session, `({ status: document.querySelector('#status').textContent, icon: document.querySelector('#state-icon').className, open: !document.querySelector('#open').hidden })`);
    if (last.status === paired && last.icon.includes('glyph-check')) {
      await chrome.send('Target.closeTarget', { targetId: pair.targetId }).catch(() => {});
      pair = null;
      await chrome.send('Target.activateTarget', { targetId: page.targetId });
      return { paired: true, status: last.status };
    }
    if (last.open) throw Error(`pairing failed: ${last.status}`);
  }
  throw Error(`not paired within ${timeout} s: ${JSON.stringify(last)}`);
}

async function menuUnlock() {
  need(menu, 'clickKey');
  await waitMenu({ state: 'locked' });
  await settle();
  await tools.menuClick(page, menu.session, '#content .kf-primary');
  return { clicked: true };
}

async function menuFill({ title }) {
  const state = await waitMenu({ state: 'logins', title });
  await settle();
  // Rows are grouped into lists; address the row by its list and position.
  const where = await tools.evaluate(menu.session, `(() => { const lists = [...document.querySelectorAll('#content > ul')];
    for (const [l, list] of lists.entries()) { const r = [...list.children].findIndex(row => row.querySelector('.kf-title')?.textContent === ${JSON.stringify(title)}); if (r >= 0) return [l + 1, r + 1]; }
    return null; })()`);
  if (!where) throw Error(`no row ${title}: ${JSON.stringify(state.rows)}`);
  const selector = `#content > ul:nth-of-type(${where[0]}) > li:nth-child(${where[1]}) .login`;
  const before = JSON.stringify(await tools.values(page.session));
  const clicks = await tools.menuAct(page, menu.session, selector, async () => JSON.stringify(await tools.values(page.session)) !== before, `fill ${title}`, note);
  await tools.waitFor(async () => !(await menuOpen()), 'menu closes after the fill');
  menu = null;
  return { filled: true, clicks };
}

const digest = value => createHash('sha256').update(value).digest('hex');
async function fields() {
  const inputs = await tools.evaluate(need(page, 'openLogin').session, `[...document.querySelectorAll('input')].map(i => ({ id: i.id, type: i.type, value: i.value }))`);
  return { fields: Object.fromEntries(inputs.map(({ id, type, value }) => [id, type === 'password' ? { type, length: value.length, sha256: digest(value) } : { type, value }])) };
}

async function clearFields() {
  await tools.evaluate(need(page, 'openLogin').session, `document.querySelectorAll('input').forEach(i => { i.value = ''; })`);
  return fields();
}

async function closeMenu() {
  if (!(await menuOpen())) { menu = null; return { closed: true }; }
  await tools.key(menu.session, 'Escape');
  await tools.waitFor(async () => !(await menuOpen()), 'menu closes on Escape');
  menu = null;
  return { closed: true };
}

async function popup() {
  need(page, 'openLogin');
  await chrome.send('Target.activateTarget', { targetId: page.targetId });
  await tools.evaluate(worker, `chrome.action.openPopup().then(() => true)`);
  const target = await tools.waitFor(async () => (await targets()).find(t => t.url === extension + 'popup.html'), 'popup');
  const session = await tools.attach(target.targetId);
  const read = () => tools.evaluate(session, `({ htmlWidth: document.documentElement.getBoundingClientRect().width, innerWidth, status: document.querySelector('#status').textContent,
    site: document.querySelector('#site').textContent, rows: [...document.querySelectorAll('.kf-row')].map(row => ({ title: row.querySelector('.kf-title')?.textContent ?? '', username: row.querySelector('.kf-username')?.textContent ?? '' })) })`);
  let result;
  for (let i = 0; i < 50; ++i) { result = await read(); if (result.rows.length) break; await sleep(200); }
  await chrome.send('Target.closeTarget', { targetId: target.targetId }).catch(() => {});
  menu = null;
  return result;
}

async function screenshot({ name }) {
  const { data } = await chrome.send('Page.captureScreenshot', { format: 'png' }, need(page, 'openLogin').session);
  return { name, png: data };
}

function note(text) { emit({ event: 'note', text: text.trim() }); }

async function quit() {
  try { await chrome?.stop(); } catch {}
  server?.close();
  if (profile) await rm(profile, { recursive: true, force: true }).catch(() => {});
  chrome = server = profile = null;
}

// A host started the way the browser starts it, before any browser runs: proves the host and app answer.
async function probeHost({ timeout = 10 }) {
  const started = performance.now();
  const child = spawn(hostPath, [`chrome-extension://${EXTENSION_ID}/`], { stdio: ['pipe', 'pipe', 'pipe'], env: browserEnvironment });
  const body = Buffer.from(JSON.stringify({ cmd: 'connect', v: 1, t: 'host' })), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  child.stdin.on('error', () => {});
  child.stdin.write(Buffer.concat([header, body]));
  try {
    return await new Promise((resolve, reject) => {
      let input = Buffer.alloc(0);
      const timer = setTimeout(() => reject(Error(`host-silent: no reply within ${timeout} s`)), timeout * 1000);
      child.stdout.on('data', chunk => {
        input = Buffer.concat([input, chunk]);
        if (input.length >= 4 && input.length >= 4 + input.readUInt32LE(0)) {
          clearTimeout(timer);
          resolve({ frame: JSON.parse(input.subarray(4, 4 + input.readUInt32LE(0))), ms: Math.round(performance.now() - started) });
        }
      });
      child.on('exit', code => { clearTimeout(timer); reject(Error(`host exited (${code}) before replying`)); });
    });
  } finally { child.stdin.end(); setTimeout(() => child.kill(), 1000); }
}

const commands = { start, probeHost, openLogin, clickKey, menuState, waitMenu, menuPair, waitPaired, menuUnlock, menuFill, fields, clearFields, closeMenu, popup, screenshot, quit };
const finish = async () => { await quit(); process.exit(0); };
let queue = Promise.resolve();
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  let command;
  try { command = JSON.parse(line); } catch { emit({ error: 'bad-command' }); return; }
  queue = queue.then(async () => {
    if (command.cmd === 'quit') { await quit(); emit({ id: command.id, done: true, result: { quit: true } }); process.exit(0); }
    const run = commands[command.cmd];
    try {
      if (!run) throw Error(`unknown command ${command.cmd}`);
      emit({ id: command.id, done: true, result: await run(command) });
    } catch (error) {
      emit({ id: command.id, done: false, error: error?.code ?? 'failed', message: error?.message ?? String(error), ...(chrome ? { browserStderr: chrome.stderr().slice(-2000) } : {}) });
    }
  });
});
lines.on('close', () => { queue = queue.then(finish); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, finish);
