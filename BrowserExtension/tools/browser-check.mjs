#!/usr/bin/env node
// Runs the real fillDocument in headless Chrome isolated worlds against test/pages; development only, never shipped.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, normalize } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromePath as findChrome, extensionDir } from './chrome-cdp.mjs';
const { fillDocument } = await import(pathToFileURL(join(extensionDir(fileURLToPath(new URL('..', import.meta.url))), 'src/fill.js')));

const chromePath = findChrome();
const pages = fileURLToPath(new URL('../test/pages/', import.meta.url));
const source = fillDocument.toString();
const credential = { username: 'alice', password: 's3cret-pw' };
const code = { totp: '123456' };
const none = { username: false, password: false, totp: false };
const login = { username: true, password: true, totp: false };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function serve() {
  const handler = async (request, response) => {
    const path = normalize(new URL(request.url, 'http://x').pathname).replace(/^\/+/, '');
    try { const body = await readFile(join(pages, path)); response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); response.end(body); }
    catch { response.writeHead(404); response.end(); }
  };
  const v4 = createServer(handler);
  await new Promise(resolve => v4.listen(0, '127.0.0.1', resolve));
  const port = v4.address().port;
  // Chrome may resolve localhost to ::1 first.
  const v6 = createServer(handler);
  await new Promise(resolve => { v6.once('error', resolve); v6.listen(port, '::1', resolve); });
  return { port, close: () => { v4.close(); v6.close(); } };
}

class CDP {
  constructor(url) { this.ws = new WebSocket(url); this.id = 0; this.pending = new Map(); this.listeners = new Set(); }
  async open() {
    await new Promise((resolve, reject) => { this.ws.onopen = resolve; this.ws.onerror = reject; });
    this.ws.onmessage = ({ data }) => {
      const message = JSON.parse(data);
      if (message.id) { const p = this.pending.get(message.id); this.pending.delete(message.id); message.error ? p.reject(new Error(`${p.method}: ${message.error.message}`)) : p.resolve(message.result); }
      else for (const listener of this.listeners) listener(message);
    };
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject, method }));
  }
  waitFor(method, sessionId, timeout = 10000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.listeners.delete(listener); reject(new Error(`timeout waiting for ${method}`)); }, timeout);
      const listener = message => { if (message.method === method && message.sessionId === sessionId) { clearTimeout(timer); this.listeners.delete(listener); resolve(message.params); } };
      this.listeners.add(listener);
    });
  }
}

async function launch() {
  const profile = await mkdtemp(join(tmpdir(), 'keeforge-browser-check-'));
  const child = spawn(chromePath, ['--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--disable-extensions', '--use-mock-keychain', '--password-store=basic',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--window-size=1280,800', 'about:blank'], { stdio: 'ignore' });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const close = async () => {
    child.kill('SIGTERM');
    await Promise.race([exited, sleep(3000).then(() => child.kill('SIGKILL'))]);
    await rm(profile, { recursive: true, force: true });
  };
  try {
    let active;
    for (let i = 0; i < 200 && !active; ++i) { await sleep(50); active = await readFile(join(profile, 'DevToolsActivePort'), 'utf8').catch(() => null); }
    if (!active) throw new Error('Chrome did not write DevToolsActivePort');
    const [port, path] = active.trim().split('\n');
    const cdp = new CDP(`ws://127.0.0.1:${port}${path}`);
    await cdp.open();
    const version = await cdp.send('Browser.getVersion');
    return { cdp, version: version.product, pid: child.pid, close };
  } catch (error) { await close(); throw error; }
}

class Tab {
  constructor(cdp) { this.cdp = cdp; this.children = new Set(); }
  async open() {
    const { targetId } = await this.cdp.send('Target.createTarget', { url: 'about:blank' });
    this.targetId = targetId;
    this.session = (await this.cdp.send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
    this.listener = message => {
      if (message.method === 'Target.attachedToTarget' && message.sessionId === this.session) this.children.add(message.params.sessionId);
    };
    this.cdp.listeners.add(this.listener);
    await this.cdp.send('Page.enable', {}, this.session);
    await this.cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true }, this.session);
    await this.cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, this.session);
    return this;
  }
  async go(url) {
    const loaded = this.cdp.waitFor('Page.loadEventFired', this.session);
    await this.cdp.send('Page.navigate', { url }, this.session);
    await loaded;
  }
  async eval(expression, session = this.session) {
    const reply = await this.cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, session);
    if (reply.exceptionDetails) throw new Error(`main world: ${reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text}`);
    return reply.result.value;
  }
  async outOfProcessFrame(url) {
    for (let i = 0; i < 100; ++i) {
      for (const session of this.children) {
        const { frame } = (await this.cdp.send('Page.getFrameTree', {}, session)).frameTree;
        if (frame.url === url) return { session, frameId: frame.id };
      }
      await sleep(50);
    }
    throw new Error(`no out-of-process frame for ${url}`);
  }
  async inProcessFrame(url) {
    const walk = tree => tree.frame.url === url ? tree.frame.id : (tree.childFrames ?? []).map(walk).find(Boolean);
    const frameId = walk((await this.cdp.send('Page.getFrameTree', {}, this.session)).frameTree);
    if (!frameId) throw new Error(`no frame for ${url}`);
    return { session: this.session, frameId };
  }
  // One world per document, reused for probe and fill like the extension's isolated world.
  async world({ session = this.session, frameId } = {}) {
    frameId ??= (await this.cdp.send('Page.getFrameTree', {}, session)).frameTree.frame.id;
    const { executionContextId } = await this.cdp.send('Page.createIsolatedWorld', { frameId, worldName: 'keeforge-check' }, session);
    return { call: async (...args) => {
      const reply = await this.cdp.send('Runtime.callFunctionOn', { functionDeclaration: source, executionContextId, arguments: args.map(value => value === undefined ? {} : { value }), returnByValue: true, awaitPromise: true }, session);
      if (reply.exceptionDetails) throw new Error(`isolated world: ${reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text}`);
      return reply.result.value;
    } };
  }
  async click(x, y) {
    for (const type of ['mousePressed', 'mouseReleased']) await this.cdp.send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }, this.session);
  }
  async clickSelector(selector) {
    const box = await this.eval(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    await this.click(...box);
  }
  async close() { this.cdp.listeners.delete(this.listener); await this.cdp.send('Target.closeTarget', { targetId: this.targetId }); }
}

const rows = [];
const check = (name, expected, actual) => rows.push({ name, expected: JSON.stringify(expected), actual: JSON.stringify(actual), ok: JSON.stringify(expected) === JSON.stringify(actual) });
const values = (tab, ids) => tab.eval(`Object.fromEntries(${JSON.stringify(ids)}.map(id => [id, document.getElementById(id).value]))`);

async function cases(cdp, port) {
  const base = `http://127.0.0.1:${port}`;
  const withTab = async (path, body) => {
    const tab = await new Tab(cdp).open();
    try { await tab.go(base + path); await body(tab, await tab.world()); }
    catch (error) { check(path, 'no exception', String(error.message)); }
    finally { await tab.close(); }
  };
  const fill = (world, token, codeOnly = false, origin = base) => world.call(origin, codeOnly ? code : credential, codeOnly, token);

  await withTab('/login.html', async (tab, world) => {
    const probe = await world.call();
    check('plain login: probe', { focused: false, active: false, touched: 0, fillable: true, token: 64 }, { ...probe, token: probe.token?.length });
    check('plain login: fill result', login, await fill(world, probe.token));
    check('plain login: page values', { u: 'alice', p: 's3cret-pw' }, await values(tab, ['u', 'p']));
  });
  await withTab('/focus.html', async (tab, world) => {
    await tab.clickSelector('#u2');
    const probe = await world.call();
    check('focus in 2nd form: probe', { focused: true, fillable: true }, { focused: probe.focused, fillable: probe.fillable });
    check('focus in 2nd form: fill result', login, await fill(world, probe.token));
    check('focus in 2nd form: only focused form written', { u1: '', p1: '', u2: 'alice', p2: 's3cret-pw' }, await values(tab, ['u1', 'p1', 'u2', 'p2']));
  });
  await withTab('/password-only.html', async (tab, world) => {
    const probe = await world.call();
    check('password-only step', [{ username: false, password: true, totp: false }, { p: 's3cret-pw' }], [await fill(world, probe.token), await values(tab, ['p'])]);
  });
  await withTab('/otp.html', async (tab, world) => {
    const probe = await world.call();
    check('one-time-code field (code-only fill)', [{ username: false, password: false, totp: true }, { u: '', c: '123456' }], [await fill(world, probe.token, true), await values(tab, ['u', 'c'])]);
  });
  await withTab('/otp-plain.html', async (tab, world) => {
    await tab.clickSelector('#c');
    const probe = await world.call();
    check('code without hint goes to the focused field', [{ username: false, password: false, totp: true }, { other: '', c: '123456' }], [await fill(world, probe.token, true), await values(tab, ['other', 'c'])]);
  });
  await withTab('/react.html', async (tab, world) => {
    await tab.eval(`(() => { const c = document.getElementById('ctl'); c.value = 'typed'; c.dispatchEvent(new Event('input', { bubbles: true })); })()`);
    check('controlled input: plain .value= is reverted (tracker sanity)', { state: '', dom: '' }, await tab.eval(`({ state: state.ctl, dom: document.getElementById('ctl').value })`));
    const probe = await world.call();
    check('controlled input: fill result', login, await fill(world, probe.token));
    check('controlled input: framework state updated', { u: 'alice', p: 's3cret-pw', domU: 'alice', domP: 's3cret-pw' }, await tab.eval(`({ u: state.u, p: state.p, domU: document.getElementById('u').value, domP: document.getElementById('p').value })`));
  });
  for (const [page, name] of [['/modal.html', 'rounded transformed overflow-hidden modal'], ['/scroll-lock-modal.html', 'fixed modal, body overflow:hidden scroll lock']]) {
    await withTab(page, async (tab, world) => {
      const probe = await world.call();
      check(`${name}: fills`, [true, login, { u: 'alice', p: 's3cret-pw' }], [probe.fillable, await fill(world, probe.token), await values(tab, ['u', 'p'])]);
    });
  }
  await withTab('/body-overflow.html', async (tab, world) => {
    await tab.eval(`document.getElementById('f').scrollIntoView({ block: 'center' })`);
    const visible = await tab.eval(`(() => { const r = document.getElementById('p').getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })()`);
    const probe = await world.call();
    check('scrolled-to login, body overflow-x:hidden: fills', [true, true, login], [visible, probe.fillable, await fill(world, probe.token)]);
  });
  await withTab('/below-fold.html', async (tab, world) => {
    const probe = await world.call();
    check('login below the fold, not scrolled (viewport rule)', { fillable: false }, { fillable: probe.fillable });
  });
  for (const technique of ['display-none', 'visibility-hidden', 'opacity-0', 'offscreen', 'clip-path', 'zero-size', 'inert', 'closed-details', 'sr-only-clip', 'content-visibility', 'contents-in-opacity-0']) {
    await withTab(`/hidden.html?h=${technique}`, async (tab, world) => {
      const probe = await world.call();
      check(`hidden ${technique}: hidden empty, visible fills`, [login, { hu: '', hp: '', vu: 'alice', vp: 's3cret-pw' }], [await fill(world, probe.token), await values(tab, ['hu', 'hp', 'vu', 'vp'])]);
    });
    await withTab(`/hidden.html?h=${technique}&only`, async (tab, world) => {
      const probe = await world.call();
      check(`hidden ${technique} alone: not fillable, nothing written`, [false, none, { hu: '', hp: '' }], [probe.fillable, await fill(world, probe.token), await values(tab, ['hu', 'hp'])]);
    });
  }
  for (const hint of [true, false]) {
    await withTab(`/decoy.html${hint ? '?hint' : ''}`, async (tab, world) => {
      const probe = await world.call();
      check(`text current-password decoy, username ${hint ? 'hinted' : 'unhinted'}: decoy empty`, [login, { u: 'alice', decoy: '', p: 's3cret-pw' }], [await fill(world, probe.token), await values(tab, ['u', 'decoy', 'p'])]);
    });
  }
  await withTab('/typeswap.html', async (tab, world) => {
    const probe = await world.call();
    check('handler swaps password to text: password not written', [none, { p: '', type: 'text' }], [await fill(world, probe.token), await tab.eval(`({ p: document.getElementById('p').value, type: document.getElementById('p').type })`)]);
  });
  await withTab('/contents.html', async (tab, world) => {
    const probe = await world.call();
    check('login under display:contents wrappers in a clipped card: fills', [true, login, { u: 'alice', p: 's3cret-pw' }], [probe.fillable, await fill(world, probe.token), await values(tab, ['u', 'p'])]);
  });
  await withTab('/shadow-open.html', async (tab, world) => {
    const probe = await world.call();
    check('open shadow root login fills', [true, login, ['alice', 's3cret-pw']], [probe.fillable, await fill(world, probe.token), await tab.eval(`[root.getElementById('u').value, root.getElementById('p').value]`)]);
  });
  await withTab('/shadow-closed.html', async (tab, world) => {
    const probe = await world.call();
    check('closed shadow root login not found', [false, none, ['', '']], [probe.fillable, await fill(world, probe.token), await tab.eval(`[root.getElementById('u').value, root.getElementById('p').value]`)]);
  });
  await withTab('/frames.html', async (tab, topWorld) => {
    const crossOrigin = `http://localhost:${port}`;
    const same = await tab.inProcessFrame(`${base}/frame-login.html`), cross = await tab.outOfProcessFrame(`${crossOrigin}/frame-login.html`);
    const box = await tab.eval(`(() => { const r = document.getElementById('cross').getBoundingClientRect(); return [r.left, r.top]; })()`);
    const inner = await tab.eval(`(() => { const r = document.getElementById('u').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`, cross.session);
    // An out-of-process frame can miss input until its compositor frame is ready; wait for real focus.
    for (let i = 0; i < 40 && !(await tab.eval(`document.hasFocus() && document.activeElement?.id === 'u'`, cross.session)); ++i) { await tab.click(box[0] + inner[0], box[1] + inner[1]); await sleep(50); }
    const sameWorld = await tab.world(same), crossWorld = await tab.world(cross);
    const [topProbe, sameProbe, crossProbe] = [await topWorld.call(), await sameWorld.call(), await crossWorld.call()];
    check('frames: [focused, fillable] top/same/cross after clicking cross field', [[false, false], [false, true], [true, true]], [topProbe, sameProbe, crossProbe].map(p => [p.focused, p.fillable]));
    check('frames: cross-origin fill with parent origin refused', [none, ''], [await fill(crossWorld, crossProbe.token, false, base), await tab.eval(`document.getElementById('u').value`, cross.session)]);
    check('frames: cross-origin fill with its own origin', [login, 'alice'], [await fill(crossWorld, crossProbe.token, false, crossOrigin), await tab.eval(`document.getElementById('u').value`, cross.session)]);
    check('frames: same-origin frame fill', [login, 'alice'], [await fill(sameWorld, sameProbe.token), await tab.eval(`document.getElementById('same').contentDocument.getElementById('u').value`)]);
  });
  await withTab('/login.html', async (tab, world) => {
    const probe = await world.call();
    check('token: main world cannot see the pin', ['undefined', false], [await tab.eval(`typeof window.__keeforgeDocumentPin`), await tab.eval(`'__keeforgeDocumentPin' in window`)]);
    check('token: wrong token writes nothing', [none, { u: '', p: '' }], [await fill(world, 'f'.repeat(64)), await values(tab, ['u', 'p'])]);
    check('token: missing token writes nothing', none, await fill(world, undefined));
    await tab.go(`${base}/login.html?next`);
    const fresh = await tab.world();
    check('token: old token refused after same-origin navigation', [none, { u: '', p: '' }], [await fill(fresh, probe.token), await values(tab, ['u', 'p'])]);
    const reprobe = await fresh.call();
    check('token: after re-probe old token refused, new one fills', [none, login], [await fill(fresh, probe.token), await fill(fresh, reprobe.token)]);
  });
  await withTab('/hostile.html', async (tab, world) => {
    const probe = await world.call();
    const result = await fill(world, probe.token);
    const page = await tab.eval(`({ values: Object.fromEntries(['hu', 'hp', 'u', 'p', 'steal'].map(id => [id, Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').get.call(document.getElementById(id))])), hits: { ...hits }, seen })`);
    // The page's own lookup above calls its getOwnPropertyDescriptor override five times.
    check('hostile overrides: isolated fill writes the right fields', [true, login, { hu: '', hp: '', u: 'alice', p: 's3cret-pw', steal: '' }], [probe.fillable, result, page.values]);
    check('hostile overrides: none reached from the isolated world', { setter: 0, Event: 0, qsa: 0, gcs: 0, gopd: 5, dispatch: 0, random: 0, pin: 0 }, page.hits);
    check('hostile: page capture listener still sees the input events', ['u', 'p'], page.seen);
  });
}

async function main() {
  const server = await serve();
  let browser;
  try {
    browser = await launch();
    const started = Date.now();
    await cases(browser.cdp, server.port);
    const elapsed = Date.now() - started;
    const width = Math.max(...rows.map(r => r.name.length));
    console.log(`${browser.version}; fillDocument from ${extensionDir(fileURLToPath(new URL('..', import.meta.url)))}/src/fill.js; ${rows.length} checks in ${elapsed} ms\n`);
    console.log(`${'RESULT'}  ${'CASE'.padEnd(width)}  EXPECTED / ACTUAL`);
    for (const row of rows) console.log(`${row.ok ? 'PASS  ' : 'FAIL  '}  ${row.name.padEnd(width)}  ${row.expected}${row.ok ? '' : `\n        ${' '.repeat(width)}  actual: ${row.actual}`}`);
    const failed = rows.filter(r => !r.ok).length;
    console.log(`\n${rows.length - failed} passed, ${failed} failed`);
    process.exitCode = failed ? 1 : 0;
  } finally {
    await browser?.close();
    server.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 2; });
