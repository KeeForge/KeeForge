#!/usr/bin/env node
// Development only: installs build/firefox temporarily in a disposable headless Firefox over WebDriver BiDi and checks the
// in-field button and menu embedding on loopback pages. No native host is registered (Firefox reads only the real
// per-user folder), so the menu shows its host-missing state. Run tools/build.sh first.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { firefoxPath, extensionDir } from './chrome-cdp.mjs';
const root = fileURLToPath(new URL('..', import.meta.url));
const sleep = ms => new Promise(done => setTimeout(done, ms));
const profile = await mkdtemp(join(tmpdir(), 'keeforge-firefox-'));
await writeFile(join(profile, 'user.js'), ['browser.shell.checkDefaultBrowser', 'datareporting.policy.dataSubmissionEnabled', 'app.update.enabled', 'browser.startup.homepage_override.mstone'].map(name => `user_pref("${name}", ${name.endsWith('mstone') ? '"ignore"' : 'false'});`).join('\n') + '\nuser_pref("extensions.originControls.grantByDefault", true);\n');
const server = createServer(async (request, response) => {
  try { const body = await readFile(join(root, 'test/pages', basename(new URL(request.url, 'http://localhost').pathname))); response.writeHead(200, { 'content-type': 'text/html' }); response.end(body); }
  catch { response.writeHead(404); response.end(); }
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
const port = server.address().port, debugPort = 9300 + Math.floor(Math.random() * 500);
const firefox = spawn(firefoxPath(), ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', String(debugPort), '--remote-allow-system-access', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, MOZ_REMOTE_ALLOW_SYSTEM_ACCESS: '1' } });
firefox.stderr.resume();
let socket;
for (let i = 0; i < 60 && !socket; i++) { await sleep(500); try { socket = await new Promise((done, fail) => { const ws = new WebSocket(`ws://127.0.0.1:${debugPort}/session`); ws.onopen = () => done(ws); ws.onerror = fail; }); } catch {} }
if (!socket) { firefox.kill('SIGKILL'); server.close(); await rm(profile, { recursive: true, force: true }); throw Error(`Firefox (${firefoxPath()}) did not open WebDriver BiDi`); }
let nextId = 0; const pending = new Map();
socket.onmessage = event => { const message = JSON.parse(event.data); const waiter = message.id && pending.get(message.id); if (waiter) { pending.delete(message.id); message.type === 'error' ? waiter.reject(Error(`${message.error}: ${message.message}`)) : waiter.resolve(message.result); } };
const command = (method, params = {}) => new Promise((resolve, reject) => { const id = ++nextId, timer = setTimeout(() => { pending.delete(id); reject(Error('timeout: ' + method)); }, 15000); pending.set(id, { resolve: v => { clearTimeout(timer); resolve(v); }, reject: e => { clearTimeout(timer); reject(e); } }); socket.send(JSON.stringify({ id, method, params })); });
const evaluate = async (context, expression) => { const r = await command('script.evaluate', { expression, target: { context }, awaitPromise: true, resultOwnership: 'none' }); if (r.type === 'exception') throw Error(r.exceptionDetails.text); return r.result.value; };
const results = [];
const check = (name, value, detail = '') => { assert.ok(value, name + (detail ? ': ' + detail : '')); results.push(name); console.log('PASS ' + name + (detail ? ` (${detail})` : '')); };
async function waitFor(fn, label) { for (let i = 0; i < 60; i++) { try { const value = await fn(); if (value) return value; } catch {} await sleep(100); } throw Error('timeout waiting for ' + label); }
try {
  await command('session.new', { capabilities: {} });
  const { extension } = await command('webExtension.install', { extensionData: { type: 'path', path: extensionDir(root, 'build/firefox') } });
  check('build/firefox installs as a temporary add-on', !!extension, extension);
  const context = (await command('browsingContext.getTree', {})).contexts[0].context;
  await command('browsingContext.navigate', { context, url: `http://localhost:${port}/inline-spy.html`, wait: 'complete' });
  await sleep(1500);
  const field = JSON.parse(await evaluate(context, `JSON.stringify(document.getElementById('u').getBoundingClientRect())`));
  const x = Math.round(field.right - 14), y = Math.round(field.top + field.height / 2);
  check('the key button is drawn at the field\'s trailing edge (hit-test finds our host)', await evaluate(context, `document.elementFromPoint(${x}, ${y}) === document.documentElement.lastElementChild && document.documentElement.lastElementChild.shadowRoot === null`));
  await command('input.performActions', { context, actions: [{ type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions: [{ type: 'pointerMove', x, y }, { type: 'pointerDown', button: 0 }, { type: 'pointerUp', button: 0 }] }] });
  const menu = await waitFor(async () => (await command('browsingContext.getTree', { root: context })).contexts[0].children.find(c => c.url.startsWith('moz-extension://') && c.url.includes('/inline.html#')), 'menu frame');
  check('a trusted click embeds the inline menu frame', true, menu.url.replace(/#.*/, '#<token>').replace(/\/\/[^/]+/, '//<uuid>'));
  const menuText = await waitFor(async () => { const text = await evaluate(menu.context, 'document.body.innerText'); return text.includes('KeeForge') && !text.includes('…') && text; }, 'menu state');
  check('the menu renders a state with its stylesheets and image loaded', await evaluate(menu.context, `getComputedStyle(document.querySelector('#viewport')).borderTopLeftRadius === '10px' && document.querySelector('.brand').naturalWidth > 0`), menuText.replace(/\s+/g, ' '));
  check('Firefox lacks visibility tracking (one-click fill is an accepted risk there)', !(await evaluate(menu.context, `'isVisible' in IntersectionObserverEntry.prototype`)));
  await sleep(1500);
  const seen = await evaluate(context, `JSON.stringify({ messages: window.__msgs, frames: window.length, entries: performance.getEntries().map(e => e.name).filter(n => n.includes('moz-extension')), html: document.documentElement.outerHTML.includes('moz-extension') })`);
  const page = JSON.parse(seen);
  check('the page receives no message and sees no extension URL (no per-install UUID)', page.messages.length === 0 && page.entries.length === 0 && !page.html, seen);
  check('window.frames does not expose the menu frame', page.frames === 0, String(page.frames));
  check('the menu frame is still open after loading (one load event, so the second-load guard does not misfire)', (await command('browsingContext.getTree', { root: context })).contexts[0].children.some(c => c.context === menu.context));
  const uuid = menu.url.split('/')[2];
  await command('browsingContext.navigate', { context, url: `http://localhost:${port}/login.html`, wait: 'complete' });
  const loads = await evaluate(context, `Promise.all(['theme.css', 'src/inline.js', 'images/icon.svg', 'popup.html'].map(n => new Promise(done => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'moz-extension://${uuid}/' + n; l.onload = () => done(n + ':loaded'); l.onerror = () => done(n + ':blocked'); document.head.append(l); }))).then(String)`);
  check('even with the UUID, a page cannot load anything but inline.html', !loads.includes(':loaded'), loads);
  await command('browsingContext.navigate', { context, url: `http://localhost:${port}/inline-signup.html`, wait: 'complete' });
  await sleep(1500);
  const fresh = JSON.parse(await evaluate(context, `JSON.stringify(document.getElementById('p').getBoundingClientRect())`));
  check('a new-password field gets the key button', await evaluate(context, `document.elementFromPoint(${Math.round(fresh.right - 14)}, ${Math.round(fresh.top + fresh.height / 2)}) === document.documentElement.lastElementChild`));
  console.log(`${results.length} Firefox checks passed`);
} catch (error) { console.error(error); process.exitCode = 1; }
finally {
  try { socket?.close(); } catch {}
  firefox.kill('SIGTERM'); await Promise.race([new Promise(done => firefox.once('exit', done)), sleep(4000).then(() => firefox.kill('SIGKILL'))]);
  server.close(); await rm(profile, { recursive: true, force: true });
}
