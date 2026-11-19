#!/usr/bin/env node
// Development only: loads the shipped manifest into a disposable headless Chrome with a disposable mock native host,
// drives test/pages over loopback HTTP and HTTPS with trusted CDP input, and saves screenshots to $SHOTS.
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { mkdtemp, mkdir, readFile, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('..', import.meta.url));
const shots = process.env.SHOTS;
if (!shots) throw Error('Set SHOTS to a screenshot output directory (the main checkout scratch directory)');
const sleep = ms => new Promise(done => setTimeout(done, ms));
const profile = await mkdtemp(join(tmpdir(), 'keeforge-inline-'));
const control = join(profile, 'control');
await mkdir(control); await mkdir(shots, { recursive: true });
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(profile, 'key.pem'), '-out', join(profile, 'cert.pem'), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], { stdio: 'ignore' });
const handler = async (request, response) => {
  try {
    const body = await readFile(join(root, 'test/pages', basename(new URL(request.url, 'http://localhost').pathname)));
    response.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' }); response.end(body);
  } catch { response.writeHead(404); response.end(); }
};
const listen = (server, host, port = 0) => new Promise(done => { server.once('error', done); server.listen(port, host, done); });
const servers = [createServer(handler), createHttpsServer({ key: await readFile(join(profile, 'key.pem')), cert: await readFile(join(profile, 'cert.pem')) }, handler)];
await listen(servers[0], '127.0.0.1'); await listen(servers[1], '127.0.0.1');
const port = servers[0].address().port, httpsPort = servers[1].address().port;
// Chrome may resolve localhost to ::1 first.
for (const [i, p] of [[0, port], [1, httpsPort]]) { const v6 = i ? createHttpsServer({ key: await readFile(join(profile, 'key.pem')), cert: await readFile(join(profile, 'cert.pem')) }, handler) : createServer(handler); await listen(v6, '::1', p); servers.push(v6); }
const secure = `https://localhost:${httpsPort}`;
const chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--enable-unsafe-extension-debugging', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--use-mock-keychain', '--password-store=basic',
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--ignore-certificate-errors', '--force-device-scale-factor=2', '--window-size=1100,760', 'about:blank'
], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let stderr = ''; chrome.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8000); });
const pending = new Map(); let nextId = 0, buffer = '';
chrome.stdio[4].on('data', chunk => {
  buffer += chunk;
  for (let end; (end = buffer.indexOf('\0')) >= 0;) {
    const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    const waiter = message.id && pending.get(message.id);
    if (waiter) { clearTimeout(waiter.timer); pending.delete(message.id); message.error ? waiter.reject(Error(waiter.method + ': ' + message.error.message)) : waiter.resolve(message.result); }
  }
});
chrome.once('exit', (code, signal) => { for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(Error(`Chrome exited (${signal || code})`)); } pending.clear(); });
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++nextId, timer = setTimeout(() => { pending.delete(id); reject(Error('timeout: ' + method)); }, 15000);
  pending.set(id, { resolve, reject, method, timer });
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
});
const results = [];
function check(name, value, detail = '') { assert.ok(value, name + (detail ? ': ' + detail : '')); results.push(name); console.log('PASS ' + name + (detail ? ` (${detail})` : '')); }
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
let theme = 'light';
async function applyTheme(session) { await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] }, session).catch(() => {}); }
async function attach(targetId) {
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Runtime.enable', {}, sessionId); await applyTheme(sessionId);
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
  await click(page.session, frame.left + 1 + point[0], frame.top + 1 + point[1]);
}
// Positive actions retry: a click inside the visibility window is refused by design, and is reported.
async function menuAct(page, menu, selector, done, label) {
  for (let attempt = 1; attempt <= 4; ++attempt) {
    await menuClick(page, menu, selector);
    for (let i = 0; i < 15; ++i) { if (await done().catch(() => false)) { if (attempt > 1) console.log(`  note: ${label} needed ${attempt} clicks`); return; } await sleep(100); }
  }
  throw Error('menu action had no effect: ' + label);
}
const values = session => evaluate(session, `Object.fromEntries([...document.querySelectorAll('input')].map(i => [i.id, i.value]))`);
const log = async () => (await readFile(join(control, 'log.jsonl'), 'utf8').catch(() => '')).split('\n').filter(Boolean).map(line => JSON.parse(line));
const requests = async type => (await log()).filter(entry => entry.request === type);
const setMock = state => writeFile(join(control, 'state.json'), JSON.stringify(state));
async function shot(session, name, clip, extra = []) {
  for (const t of ['light', 'dark']) {
    theme = t; for (const s of [session, ...extra]) await applyTheme(s);
    await sleep(350);
    const { data } = await send('Page.captureScreenshot', { format: 'png', ...(clip ? { clip: { ...clip, scale: 1 } } : {}) }, session);
    await writeFile(join(shots, `${name}-${t}.png`), Buffer.from(data, 'base64'));
  }
  theme = 'light'; for (const s of [session, ...extra]) await applyTheme(s);
}
async function menuClip(page, field) {
  const r = await rect(page.session, field), [frame] = await ui(page.session, 'IFRAME');
  const left = Math.min(r.left, frame.left) - 24, top = Math.min(r.top, frame.top) - 24;
  return { x: left, y: top, width: Math.max(r.right, frame.right) - left + 24, height: Math.max(r.bottom, frame.bottom) - top + 30 };
}
try {
  console.log((await send('Browser.getVersion')).product);
  const { id } = await send('Extensions.loadUnpacked', { path: resolve(root) });
  check('shipped manifest loads through Extensions.loadUnpacked', !!id, id);
  const extension = `chrome-extension://${id}/`;
  const wrapper = join(profile, 'mock-host'), quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  await writeFile(wrapper, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(join(root, 'tools/mock-host.mjs'))} --control ${quote(control)}\n`); await chmod(wrapper, 0o700);
  await mkdir(join(profile, 'NativeMessagingHosts'), { recursive: true });
  await writeFile(join(profile, 'NativeMessagingHosts/com.keevault.browser.json'), JSON.stringify({ name: 'com.keevault.browser', description: 'Disposable KeeForge mock', path: wrapper, type: 'stdio', allowed_origins: [extension] }));
  await setMock({ scenario: 'locked' });
  // Watch every runtime message the background receives.
  const worker = await waitFor(async () => (await send('Target.getTargets')).targetInfos.find(t => t.type === 'service_worker' && t.url.startsWith(extension)), 'service worker');
  const sw = await attach(worker.targetId);
  await evaluate(sw, `globalThis.__seen = []; chrome.runtime.onMessage.addListener(m => { globalThis.__seen.push(m?.type); })`);

  // In-field buttons on an HTTPS page.
  const page = await tab(`${secure}/inline.html`);
  const initial = await visibleButtons(page.session);
  const forField = async id => !!(await buttonFor(page.session, '#' + id));
  check('buttons in user-name, password and one-time-code fields only (not the text decoy or display:none field)', initial.length === 3 && await forField('u') && await forField('p') && await forField('c') && !(await forField('decoy')), `${initial.length} buttons`);
  const u = await rect(page.session, '#u'), ub = await buttonFor(page.session, '#u');
  check('button is 20 px, vertically centred at the trailing edge', ub.right - ub.left === 20 && Math.abs((ub.top + ub.bottom) / 2 - (u.top + u.bottom) / 2) < 1 && u.right - ub.right <= 6 && u.right - ub.right >= 2);
  check('UI lives in one closed shadow root', (await nodes(page.session)).filter(n => n.shadowRootType === 'closed').length === 1);
  check('page attributes and padding unchanged', await evaluate(page.session, `[...document.querySelectorAll('input')].every(i => i.getAttributeNames().every(n => ['id','autocomplete','placeholder','type','style'].includes(n))) && getComputedStyle(document.getElementById('u')).paddingRight === '8px'`));
  check('main world cannot reach the shadow root, iframe, pin or field reference', await evaluate(page.session, `document.documentElement.lastElementChild.shadowRoot === null && !document.querySelector('iframe') && window.__keeforgeDocumentPin === undefined && window.__keeforgeInlineField === undefined`));
  // CDP reaches into the closed root only to dispatch an untrusted DOM click from the main world.
  const { object } = await send('DOM.resolveNode', { backendNodeId: initial[0].id }, page.session);
  await send('Runtime.callFunctionOn', { objectId: object.objectId, functionDeclaration: 'function(){this.click();this.dispatchEvent(new MouseEvent("click",{bubbles:true}))}' }, page.session);
  await sleep(500);
  check('synthetic (untrusted) click does not open the menu', (await menus()).length === 0);
  await click(page.session, u.left + 20, (u.top + u.bottom) / 2); await sleep(300);
  check('nothing reaches the background or native host before the first button click', (await evaluate(sw, 'globalThis.__seen.length')) === 0 && (await log()).length === 0);
  await shot(page.session, 'button-login', { x: u.left - 30, y: u.top - 70, width: 400, height: 250 });

  // Unpaired -> pairing tab -> locked -> unlock refresh -> logins.
  let menu = await openMenu(page, '#u');
  await waitFor(async () => (await text(menu)).includes(await evaluate(sw, `chrome.i18n.getMessage('notPaired')`)), 'unpaired state');
  check('trusted click embeds inline.html under the shipped CSP on an HTTPS page; not-paired state shown', true);
  check('first native traffic happens only after the click', (await log()).length > 0);
  await sleep(600);
  await menuAct(page, menu, '#content button', async () => (await send('Target.getTargets')).targetInfos.some(t => t.url === extension + 'pair.html'), 'Pair');
  const pairTarget = await waitFor(async () => (await send('Target.getTargets')).targetInfos.find(t => t.type === 'page' && t.url === extension + 'pair.html'), 'pairing tab');
  const pair = await attach(pairTarget.targetId);
  await waitFor(async () => (await text(pair)).includes('KeeForge'), 'pairing complete');
  await send('Target.activateTarget', { targetId: page.targetId });
  const lockedText = await evaluate(sw, `chrome.i18n.getMessage('locked')`);
  await waitFor(async () => (await text(menu)).includes(lockedText), 'locked state after pairing');
  check('pairing in its own tab, then the open menu shows locked by itself', true);
  await sleep(400);
  await shot(page.session, 'menu-locked', await menuClip(page, '#u'), [menu]);
  await menuAct(page, menu, '#content .primary', async () => (await requests('unlock')).length >= 1, 'Unlock');
  await sleep(1500);
  check('unlock request sent once; menu still locked while the app is', (await requests('unlock')).length === 1 && (await text(menu)).includes(lockedText));
  await setMock({ scenario: 'mixed' });
  await waitFor(async () => (await text(menu)).includes('Example'), 'logins after unlock', 40);
  check('menu lists the logins after unlock without another click', (await text(menu)).includes('demo') && (await text(menu)).includes('Work login'));
  check('matches asked only for the page origin', (await requests('matches')).every(r => r.origin === secure));
  await sleep(400);
  await shot(page.session, 'menu-logins', await menuClip(page, '#u'), [menu]);
  await menuAct(page, menu, '.login', async () => (await values(page.session)).p === 'mock-password', 'login fill');
  const filled = await values(page.session);
  check('login fills user name and password, not the code field', filled.u === 'demo' && filled.c === '' && (await requests('credential')).at(-1).totp === undefined);
  await waitFor(async () => (await menus()).length === 0, 'close on fill');
  check('menu closes after a successful fill', true);

  // One-time-code field: code only.
  await evaluate(page.session, `document.querySelectorAll('input').forEach(i => i.value = '')`);
  menu = await openMenu(page, '#c');
  await waitFor(async () => (await text(menu)).includes('Example'), 'code rows');
  check('code field offers only entries with a code', !(await text(menu)).includes('Work login'));
  await menuAct(page, menu, '.login', async () => (await values(page.session)).c === '123456', 'code fill');
  check('code field fills the code only (totp request, user name/password untouched)', (await values(page.session)).u === '' && (await values(page.session)).p === '' && (await requests('credential')).at(-1).totp === true);

  // Confirm state while the app holds the credential request.
  await evaluate(page.session, `document.querySelectorAll('input').forEach(i => i.value = '')`);
  await setMock({ scenario: 'mixed', credentialDelay: 5000 });
  menu = await openMenu(page, '#p');
  await waitFor(async () => (await text(menu)).includes('Example'), 'rows for confirm');
  const confirmText = await evaluate(sw, `chrome.i18n.getMessage('confirm')`);
  await menuAct(page, menu, '.login', async () => (await text(menu)).includes(confirmText), 'confirm state');
  await shot(page.session, 'menu-confirm', await menuClip(page, '#p'), [menu]);
  await waitFor(async () => (await values(page.session)).p === 'mock-password', 'fill after confirm', 80);
  check('"Confirm in KeeForge" shown while the app authenticates, then fills', true);
  await setMock({ scenario: 'mixed' });

  // Clickjacking: occluded and transparent menus refuse trusted clicks and keyboard activation.
  await evaluate(page.session, `document.querySelectorAll('input').forEach(i => i.value = '')`);
  menu = await openMenu(page, '#p');
  await waitFor(async () => (await text(menu)).includes('Example'), 'rows for clickjacking');
  check('Chrome exposes IntersectionObserver visibility tracking in the menu', await evaluate(menu, `'isVisible' in IntersectionObserverEntry.prototype`));
  for (const [mode, setup] of [
    ['occluded (overlay with pointer-events:none)', `(() => { const d = document.createElement('div'); d.id = 'cover'; d.style.cssText = 'position:fixed;inset:0;background:#fff;opacity:.98;pointer-events:none;z-index:2147483647'; document.documentElement.append(d); })()`],
    ['transparent (host opacity 0)', `[...document.querySelectorAll('html > div')].at(-1).style.setProperty('opacity', '0', 'important')`],
    ['transparent (html opacity 0.1)', `document.documentElement.style.opacity = '0.1'`]
  ]) {
    await evaluate(page.session, setup);
    await sleep(800);
    await menuClick(page, menu, '.login');
    await evaluate(menu, `document.querySelector('.login').focus()`); await key(menu, 'Enter');
    await sleep(700);
    check(`${mode} menu does not fill on trusted click or Enter`, (await values(page.session)).p === '' && (await menus()).length === 1);
    await evaluate(page.session, `document.getElementById('cover')?.remove(); for (const d of document.querySelectorAll('html > div')) d.style.removeProperty('opacity'); document.documentElement.style.opacity = ''`);
  }
  await menuAct(page, menu, '.login', async () => (await values(page.session)).p === 'mock-password', 'fill once visible again');
  check('the same menu fills once it has been fully visible again', true);

  // Empty state; Escape closes and returns focus to the field.
  await setMock({ scenario: 'empty' });
  menu = await openMenu(page, '#u');
  await waitFor(async () => (await text(menu)).includes(`localhost:${httpsPort}`) && !(await text(menu)).includes(await evaluate(sw, `chrome.i18n.getMessage('loading')`)), 'empty state');
  await sleep(300);
  await shot(page.session, 'menu-empty', await menuClip(page, '#u'), [menu]);
  await key(menu, 'Escape');
  await waitFor(async () => (await menus()).length === 0, 'Escape closes');
  check('no-logins state; Escape closes the menu and returns focus to the field', await evaluate(page.session, `document.activeElement.id === 'u'`));
  menu = await openMenu(page, '#u'); await sleep(300);
  await click(page.session, 900, 600);
  await waitFor(async () => (await menus()).length === 0, 'outside click closes');
  check('a click elsewhere closes the menu', true);

  // App not running, then started from the menu.
  await setMock({ scenario: 'mixed', available: false });
  for (const pid of new Set((await log()).map(entry => entry.pid))) { try { process.kill(pid); } catch {} }
  await sleep(500);
  menu = await openMenu(page, '#u');
  const notRunning = await evaluate(sw, `chrome.i18n.getMessage('appUnavailable')`);
  await waitFor(async () => (await text(menu)).includes(notRunning), 'not-running state');
  await sleep(300);
  await shot(page.session, 'menu-not-running', await menuClip(page, '#u'), [menu]);
  await menuAct(page, menu, '#content .primary', async () => (await log()).some(entry => entry.cmd === 'launch'), 'Open KeeForge');
  await setMock({ scenario: 'mixed', available: true });
  await waitFor(async () => (await text(menu)).includes('Example'), 'logins after launch', 60);
  check('app-not-running state; Open KeeForge sends launch and the menu shows logins once the app runs', true);
  await key(menu, 'Escape'); await waitFor(async () => (await menus()).length === 0, 'close');

  // Main world after a menu has been opened.
  menu = await openMenu(page, '#u'); await waitFor(async () => (await text(menu)).includes('Example'), 'rows');
  check('page cannot read the token, menu text or shadow root while the menu is open', await evaluate(page.session, `(() => { const host = [...document.querySelectorAll('html > div')].at(-1); let href = 'unreadable'; try { href = frames[0].location.href; } catch {} return host.shadowRoot === null && host.childNodes.length === 0 && !document.querySelector('iframe') && !document.documentElement.innerHTML.includes('inline.html') && !document.body.innerText.includes('Example') && href === 'unreadable' && Object.keys(window).every(k => !k.startsWith('__keeforge')); })()`));
  await key(menu, 'Escape'); await waitFor(async () => (await menus()).length === 0, 'close');

  // Toolbar popup still works.
  await evaluate(page.session, `document.querySelectorAll('input').forEach(i => i.value = '')`);
  await send('Target.activateTarget', { targetId: page.targetId });
  check('toolbar popup opens', (await evaluate(sw, `chrome.action.openPopup().then(() => true)`)) === true);
  const popup = await attach((await waitFor(async () => (await send('Target.getTargets')).targetInfos.find(t => t.url === extension + 'popup.html'), 'popup')).targetId);
  await waitFor(async () => (await text(popup)).includes('Example'), 'popup rows');
  await evaluate(popup, `document.querySelector('.login').click()`);
  await waitFor(async () => (await values(page.session)).p === 'mock-password', 'popup fill');
  check('toolbar popup lists logins and fills the page', (await values(page.session)).u === 'demo');

  // Show-password control and verification-code fixtures.
  const reveal = await tab(`${secure}/inline-reveal.html`);
  const eye = await rect(reveal.session, '#reveal'), eyeButton = await buttonFor(reveal.session, '#p');
  check('button sits left of a site show-password control', eyeButton && eyeButton.right <= eye.left, eyeButton && `${eyeButton.right} <= ${eye.left}`);
  const field = await rect(reveal.session, '#u');
  await shot(reveal.session, 'button-show-password', { x: field.left - 30, y: field.top - 70, width: 400, height: 200 });
  await send('Target.closeTarget', { targetId: reveal.targetId });
  const otp = await tab(`${secure}/inline-otp.html`);
  const code = await rect(otp.session, '#c');
  check('button in a stand-alone one-time-code field', !!(await buttonFor(otp.session, '#c')));
  await shot(otp.session, 'button-code', { x: code.left - 30, y: code.top - 120, width: 400, height: 200 });
  await send('Target.closeTarget', { targetId: otp.targetId });

  // Fields added later, scrolling, resizing and hiding.
  const spa = await tab(`${secure}/inline-spa.html`);
  await waitFor(async () => (await visibleButtons(spa.session)).length === 2, 'SPA fields get buttons');
  check('fields inserted later get buttons', true);
  const before = await buttonFor(spa.session, '#p');
  await evaluate(spa.session, 'scrollBy(0, 150)'); await sleep(250);
  const scrolled = await buttonFor(spa.session, '#p');
  check('button follows the field on scroll', scrolled && Math.abs(before.top - 150 - scrolled.top) < 1);
  await send('Emulation.setDeviceMetricsOverride', { width: 700, height: 700, deviceScaleFactor: 2, mobile: false }, spa.session); await sleep(400);
  const resized = await buttonFor(spa.session, '#p'), resizedField = await rect(spa.session, '#p');
  check('button follows the field on resize', resized && Math.abs(resizedField.right - 4 - resized.right) < 1 && resized.left !== scrolled.left);
  await evaluate(spa.session, `document.getElementById('p').style.visibility = 'hidden'`); await sleep(700);
  check('button hides with its field', !(await buttonFor(spa.session, '#p')));
  await send('Target.closeTarget', { targetId: spa.targetId });

  // Cross-origin frame: its own buttons and its own origin.
  const framed = await tab(`http://127.0.0.1:${port}/frames.html`);
  await sleep(500);
  const crossTarget = await waitFor(async () => (await send('Target.getTargets')).targetInfos.find(t => t.type === 'iframe' && t.url === `http://localhost:${port}/frame-login.html`), 'cross-origin frame target');
  const cross = { session: await attach(crossTarget.targetId) }; await send('DOM.enable', {}, cross.session);
  check('cross-origin frame has its own two buttons', (await visibleButtons(cross.session)).length === 2);
  check('same-origin frame buttons are drawn by that frame, parent has none', (await visibleButtons(framed.session)).length === 0);
  const offset = await evaluate(framed.session, `(() => { const r = document.getElementById('cross').getBoundingClientRect(); return [r.left + 2, r.top + 2]; })()`);
  const crossButton = await buttonFor(cross.session, '#u');
  const beforeMenus = new Set((await menus()).map(t => t.targetId));
  await click(framed.session, offset[0] + (crossButton.left + crossButton.right) / 2, offset[1] + (crossButton.top + crossButton.bottom) / 2);
  const crossMenu = await attach((await waitFor(async () => (await menus()).find(t => !beforeMenus.has(t.targetId)), 'cross-frame menu')).targetId);
  await waitFor(async () => (await text(crossMenu)).includes(`localhost:${port}`) && (await text(crossMenu)).includes('Example'), 'cross-frame origin');
  check('cross-origin frame menu is matched with the frame origin', (await requests('matches')).at(-1).origin === `http://localhost:${port}`);
  const [crossFrame] = await ui(cross.session, 'IFRAME');
  const point = await evaluate(crossMenu, `(() => { const r = document.querySelector('.login').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()`);
  for (let attempt = 0; attempt < 4 && (await values(cross.session)).p !== 'mock-password'; ++attempt) {
    await click(framed.session, offset[0] + crossFrame.left + 1 + point[0], offset[1] + crossFrame.top + 1 + point[1]);
    await sleep(1200);
  }
  await waitFor(async () => (await values(cross.session)).p === 'mock-password', 'cross-frame fill');
  check('cross-origin frame fills only that frame', (await evaluate(framed.session, `document.getElementById('same').contentDocument.getElementById('p').value`)) === '');

  // Embedding: only the content-script iframe may load inline.html.
  const prober = await tab(`${secure}/login.html`);
  await evaluate(prober.session, `for (const name of ['popup.html', 'pair.html', 'inline.html#x']) { const f = document.createElement('iframe'); f.src = ${JSON.stringify(extension)} + name; document.body.append(f); }`);
  await sleep(1200);
  const probes = (await send('Target.getTargets')).targetInfos.filter(t => t.type === 'iframe' && t.parentFrameId === prober.targetId).map(t => t.url);
  const fetched = await evaluate(prober.session, `Promise.all(['popup.html', 'pair.html', 'inline.html'].map(n => fetch(${JSON.stringify(extension)} + n).then(() => 'loaded', () => 'blocked')))`);
  check('a web page cannot frame or fetch popup.html, pair.html or the static inline.html URL', probes.length === 3 && probes.every(url => url === 'chrome-extension://invalid/') && fetched.every(r => r === 'blocked'), probes.join(' '));
  const top = await tab(extension + 'inline.html#forged-token');
  check('top-level inline.html is inert', await evaluate(top.session, `document.querySelectorAll('button').length === 0`));
  console.log(`${results.length} checks passed; screenshots in ${shots}`);
} catch (error) {
  console.error(error); console.error('mock log tail', JSON.stringify((await log()).slice(-12))); process.exitCode = 1;
} finally {
  chrome.kill('SIGTERM');
  await Promise.race([new Promise(done => chrome.once('exit', done)), sleep(3000).then(() => chrome.kill('SIGKILL'))]);
  for (const pid of new Set((await log()).map(entry => entry.pid))) { try { process.kill(pid); } catch {} }
  for (const server of servers) server.close();
  await rm(profile, { recursive: true, force: true });
}
