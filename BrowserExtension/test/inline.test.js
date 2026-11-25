import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { Background, prepareInlineDocument } from '../src/background.js';
import { fillDocument } from '../src/fill.js';
import { FakeTimers, Event } from './fakes.js';
function setup(kind = 'login', documentId = 'doc') {
  if (documentId === null) documentId = undefined;
  const sender = { id: 'self', tab: { id: 7 }, frameId: 3, documentId, url: 'https://frame.example/path', origin: 'https://frame.example' };
  const menuSender = { id: 'self', tab: { id: 7 }, frameId: 9, url: 'chrome-extension://self/inline.html#token' };
  const requests = [], closed = [], fills = [];
  let pin = 'pin', currentDocument = documentId;
  const api = {
    runtime: { id: 'self', getURL: path => 'chrome-extension://self/' + path, onMessage: new Event() },
    tabs: { get: async () => ({ url: 'https://top.example/' }), sendMessage: async (...args) => closed.push(args), create: async () => {} },
    scripting: { executeScript: async ({ target, func }) => [{ frameId: 3, documentId: currentDocument, result: func === prepareInlineDocument ? { kind, token: pin } : { token: pin, origin: sender.origin, href: sender.url } }] }
  };
  const connection = { getState: () => ({ state: 'ready' }), open: async () => {}, close() {}, request: async (type, fields) => {
    requests.push({ type, fields });
    if (type === 'matches') return { ok: true, entries: [{ entry: 'with-code', hasTotp: true }, { entry: 'without-code', hasTotp: false }], locked: 0 };
    return type === 'credential' ? { ok: true, ...(fields.totp ? { totp: '123456' } : { username: 'demo', password: 'disposable' }) } : { ok: true };
  } };
  const b = new Background({ api, connection, timers: new FakeTimers(), injectCredential: async (target, value, codeOnly) => fills.push({ target, value: { ...value }, codeOnly }) });
  const open = () => b.openMenu(sender);
  const call = (token, action, fields = {}, from = menuSender) => b.handleMenu({ token, action, ...fields }, from);
  return { b, api, sender, menuSender, requests, closed, fills, connection, open, call, navigate() { pin = 'new'; currentDocument = 'new-doc'; } };
}
test('inline selection derives tab/frame/document/origin and kind from sender and isolated inspection only', async () => {
  const s = setup();
  assert.deepEqual(s.requests, []);
  s.b.listen();
  const listener = [...s.api.runtime.onMessage.listeners][0];
  const response = await new Promise(resolve => listener({ type: 'openInlineMenu', tabId: 999, frameId: 0, documentId: 'forged', origin: 'https://evil.example', kind: 'code' }, s.sender, resolve));
  const session = s.b.menus.get(7);
  assert.deepEqual({ tab: session.tabId, frame: session.frameId, document: session.documentId, origin: session.origin, kind: session.kind }, { tab: 7, frame: 3, document: 'doc', origin: 'https://frame.example', kind: 'login' });
  assert.ok(response.token.length >= 32); assert.deepEqual(s.requests, []);
  await s.call(response.token, 'state');
  assert.deepEqual(s.requests, [{ type: 'matches', fields: { origin: 'https://frame.example' } }]);
});
test('inline refuses opaque/insecure/mismatched or nonextension content senders', async () => {
  for (const patch of [{ origin: 'null' }, { origin: 'https://evil.example' }, { id: 'other' }, { tab: undefined }, { url: 'http://evil.example', origin: 'http://evil.example' }]) {
    const s = setup(); await assert.rejects(s.b.openMenu({ ...s.sender, ...patch })); assert.deepEqual(s.requests, []);
  }
});
test('token replacement revokes the old menu, closes only its recorded frame, rejects wrong senders', async () => {
  const s = setup(), first = await s.open(), second = await s.open();
  assert.notEqual(first.token, second.token);
  assert.deepEqual(s.closed[0], [7, { type: 'closeInlineMenu', token: first.token, refocus: false }, { frameId: 3, documentId: 'doc' }]);
  await assert.rejects(s.call(first.token, 'state'));
  for (const patch of [{ id: 'other' }, { frameId: 0 }, { tab: { id: 8 } }, { tab: undefined }, { url: 'chrome-extension://self/popup.html' }, { url: 'chrome-extension://self/inline.html.evil' }, { url: 'https://example.com/inline.html' }]) await assert.rejects(s.call(second.token, 'state', {}, { ...s.menuSender, ...patch }));
  assert.deepEqual(s.requests, []);
});
for (const kind of ['login', 'code']) test(`${kind} inline field filters rows, requests correct reply kind and closes after guarded fill`, async () => {
  const s = setup(kind), { token } = await s.open();
  const reply = await s.call(token, 'state'); assert.equal(reply.entries.length, kind === 'code' ? 1 : 2);
  assert.deepEqual(await s.call(token, 'fill', { entry: 'with-code', db: 'db' }), { ok: true });
  assert.equal(s.requests.at(-1).fields.totp, kind === 'code' ? true : undefined);
  assert.equal(s.fills[0].codeOnly, kind === 'code'); assert.equal(s.fills[0].target.inline, true);
  assert.equal(s.b.menus.size, 0); assert.equal(s.closed.length, 1);
  await assert.rejects(s.call(token, 'state'));
});
test('secondary code action, wrong reply kind and document replacement retain safeguards', async () => {
  const s = setup(), { token } = await s.open();
  await s.call(token, 'fill', { entry: 'with-code', db: 'db', totp: true }); assert.equal(s.fills[0].codeOnly, true);
  for (const mode of ['wrong-kind', 'navigate', 'replace-session', 'close']) {
    const s = setup(), { token } = await s.open(), request = s.connection.request;
    s.connection.request = async (...args) => {
      const value = await request(...args);
      if (mode === 'wrong-kind') value.totp = '123456';
      if (mode === 'navigate') s.navigate();
      if (mode === 'replace-session') await s.open();
      if (mode === 'close') await s.b.closeMenu(s.b.menus.get(7));
      return value;
    };
    await assert.rejects(s.call(token, 'fill', { entry: 'with-code', db: 'db' })); assert.equal(s.fills.length, 0);
  }
});
test('Firefox frame targeting without documentId still refuses stale pins', async () => {
  const s = setup('login', null), { token } = await s.open();
  s.navigate(); await assert.rejects(s.call(token, 'state')); assert.equal(s.requests.length, 0);
});
test('openMenu refuses a document whose inspection disagrees with the prepared field (origin, document or pin)', async () => {
  for (const change of [{ origin: 'https://other.example', href: 'https://other.example/' }, { token: 'replaced' }]) {
    const s = setup(); let calls = 0;
    const execute = s.api.scripting.executeScript;
    s.api.scripting.executeScript = async options => { const results = await execute(options); if (++calls === 2) results[0].result = { ...results[0].result, ...change }; return results; };
    await assert.rejects(s.open()); assert.equal(s.b.menus.size, 0);
  }
});
test('the first inline document owns the session; another document with the token is refused and closes it', async () => {
  const s = setup(), { token } = await s.open();
  await s.call(token, 'state', {}, { ...s.menuSender, documentId: 'menu-1' });
  await assert.rejects(s.call(token, 'state', {}, { ...s.menuSender, documentId: 'menu-2' }));
  assert.equal(s.b.menus.size, 0); assert.equal(s.closed.length, 1);
});
test('menu close and fill reach only the recorded content frame, through the browser, with refocus', async () => {
  let s = setup(), { token } = await s.open();
  assert.deepEqual(await s.call(token, 'close', { refocus: true }), { ok: true });
  assert.deepEqual(s.closed, [[7, { type: 'closeInlineMenu', token, refocus: true }, { frameId: 3, documentId: 'doc' }]]);
  s = setup(); ({ token } = await s.open());
  await s.call(token, 'fill', { entry: 'without-code', db: 'db' });
  assert.deepEqual(s.closed, [[7, { type: 'closeInlineMenu', token, refocus: true }, { frameId: 3, documentId: 'doc' }]]);
});
test('a user-name step session injects the user name only', async () => {
  const s = setup('username'), { token } = await s.open();
  assert.deepEqual(await s.call(token, 'fill', { entry: 'without-code', db: 'db' }), { ok: true });
  assert.equal(s.fills[0].target.kind, 'username');
  const { injectCredential } = await import('../src/fill.js');
  let args;
  await injectCredential({ scripting: { executeScript: async options => { args = options.args; return [{ frameId: 3, result: { username: true } }]; } } }, s.fills[0].target, { username: 'demo', password: 'secret' });
  assert.deepEqual(args[1], { username: 'demo' });
});
test('popup selection closes an open inline menu for that tab before replacing the pin', async () => {
  const s = setup(), { token } = await s.open();
  s.api.scripting.executeScript = async ({ func }) => [{ frameId: 0, documentId: 'doc', result: func.name === 'inspectDocument' ? { token: 'p', origin: 'https://top.example', href: 'https://top.example/' } : { fillable: true, focused: true, token: 'p' } }];
  await s.b.handle({ type: 'getTarget', tabId: 7 });
  assert.equal(s.b.menus.size, 0); assert.deepEqual(s.closed[0][1], { type: 'closeInlineMenu', token, refocus: false });
});
test('manifest exposes only inline.html and registers the content script at document_start', async () => {
  const manifest = JSON.parse(await readFile(new URL('../manifest.json', import.meta.url), 'utf8'));
  assert.deepEqual(manifest.web_accessible_resources.map(r => r.resources), [['inline.html']]);
  assert.equal(manifest.content_scripts[0].run_at, 'document_start');
});
test('the in-field key glyph is the path of images/key.svg', async () => {
  const svg = await readFile(new URL('../images/key.svg', import.meta.url), 'utf8');
  const source = await readFile(new URL('../src/content.js', import.meta.url), 'utf8');
  assert.equal(source.match(/const KEY_PATH = '([^']+)'/)[1], svg.match(/ d="([^"]+)"/)[1]);
  assert.doesNotMatch(await readFile(new URL('../inline.html', import.meta.url), 'utf8'), /<svg/);
});

// A minimal DOM for running src/content.js in a vm context.
function contentPage({ origin = 'https://example.com', readyState = 'complete', withInput = true } = {}) {
  const callbacks = [], events = {}, requests = [], created = [], observers = [];
  class Node {
    constructor(tag) { this.tag = tag; this.style = { cssText: '' }; this.listeners = {}; this.children = []; this.isConnected = true; this.dataset = {}; this.attributes = {}; }
    append(...nodes) { for (const node of nodes) { node.parentNode = this; node.isConnected = true; } this.children.push(...nodes); }
    attachShadow() { return this.root = new Node('shadow'); }
    setAttribute(name, value) { this.attributes[name] = value; }
    getAttribute(name) { return this.attributes[name] ?? null; }
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
    dispatch(type, event = {}) { for (const fn of this.listeners[type] || []) fn(event); }
    remove() { this.isConnected = false; }
    querySelectorAll() { return []; }
    matches() { return false; }
    focus() { document.activeElement = this; }
    getBoundingClientRect() {
      if (this.rect) return this.rect;
      const [left, top, width, height] = ['left', 'top', 'width', 'height'].map(key => parseFloat(this.style[key]) || 0);
      return { left, top, width, height, right: left + width, bottom: top + height };
    }
  }
  class Input extends Node {
    type = 'text'; autocomplete = 'username'; form = null; rect = { left: 10, right: 250, top: 30, bottom: 70, width: 240, height: 40 };
    getClientRects() { return [this.rect]; }
  }
  const input = new Input('input');
  const styles = new Map();
  const html = new Node('html');
  const document = { documentElement: html, body: new Node('body'), readyState, activeElement: null, hasFocus: () => true, fullscreenElement: null,
    createElement: tag => { const node = new Node(tag); if (tag === 'iframe') node.contentDocument = null; created.push(node); return node; },
    createElementNS: (ns, tag) => new Node(tag), querySelector: () => null,
    querySelectorAll: selector => withInput && selector === 'input' ? [input] : [], getElementsByTagName: () => (withInput ? [input] : []) };
  input.ownerDocument = document;
  let runtimeListener;
  const context = { document, Element: class { get shadowRoot() { return this.openRoot ?? null; } }, HTMLInputElement: Input, innerWidth: 800, innerHeight: 600, crypto, origin, location: { href: 'https://example.com/', origin },
    getComputedStyle: node => ({ display: 'block', visibility: 'visible', opacity: '1', direction: 'ltr', backgroundColor: 'rgb(255, 255, 255)', colorScheme: 'normal', color: 'rgba(0, 0, 0, 0)', ...styles.get(node) }),
    performance: { now: () => 1000 }, MutationObserver: class { constructor(fn) { this.fn = fn; observers.push(this); } observe(target, options) { this.options = options; } disconnect() { this.off = true; } },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => assert.fail('no interval'), requestAnimationFrame: callback => callbacks.push(callback),
    addEventListener: (type, fn, capture) => { assert.equal(capture, true, type); (events[type] ??= []).push(fn); },
    chrome: { i18n: { getMessage: key => key }, runtime: { id: 'self', getURL: path => 'chrome-extension://self/' + path, onMessage: { addListener: fn => { runtimeListener = fn; } }, sendMessage: async request => { requests.push(request); return { token: 'menu-token' }; } } } };
  const fire = (type, event = {}) => { for (const fn of events[type] || []) fn(event); };
  // Runs one frame: callbacks queued meanwhile (the open menu's watcher) wait for the next.
  const frames = () => { for (const callback of callbacks.splice(0)) callback(); };
  return { context, document, input, html, events, fire, frames, requests, created, observers, styles, runtime: (message, sender = { id: 'self' }) => runtimeListener(message, sender), Node };
}
const contentSource = () => readFile(new URL('../src/content.js', import.meta.url), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
test('classic content script contains the exact shared fill function, registers listeners at start and never messages on discovery', async () => {
  const source = await contentSource();
  assert.equal(source.split('// BEGIN shared fillDocument\n')[1].split('\n// END shared fillDocument')[0], fillDocument.toString());
  assert.ok(!/^import /m.test(source));
  const page = contentPage({ readyState: 'loading' });
  vm.runInNewContext(source, page.context);
  // Listeners exist before any page script could add its own; nothing else happens until the DOM is ready.
  for (const type of ['pointerdown', 'keydown', 'DOMContentLoaded', 'focusin']) assert.ok(page.events[type], type);
  assert.equal(page.events.message, undefined);
  assert.equal(page.html.children.length, 0); assert.equal(page.observers.length, 0);
  page.fire('DOMContentLoaded'); page.frames();
  assert.equal(page.html.children.length, 1);
  page.fire('resize'); page.fire('scroll'); page.frames();
  assert.deepEqual(page.requests, []);
  assert.ok(page.observers[0].options.attributeFilter.includes('style'));
});
test('a document without inputs gets no host or update loop until an input appears', async () => {
  const page = contentPage({ withInput: false });
  vm.runInNewContext(await contentSource(), page.context);
  page.frames();
  assert.equal(page.html.children.length, 0);
  assert.equal(page.observers.length, 1); assert.equal(JSON.stringify(page.observers[0].options), '{"childList":true,"subtree":true}');
  page.observers[0].fn([]); assert.equal(page.html.children.length, 0);
});
test('an input that exists only inside an open shadow root wakes the script, and its root is observed', async () => {
  const page = contentPage({ withInput: false });
  const root = { querySelectorAll: () => [], querySelector: () => null }, shadowHost = { openRoot: root };
  page.document.querySelectorAll = selector => selector === '*' ? [shadowHost] : [];
  vm.runInNewContext(await contentSource(), page.context); page.frames();
  // The empty root is watched by the gate; nothing is drawn yet.
  assert.equal(page.html.children.length, 0); assert.equal(page.observers.length, 1);
  root.querySelector = selector => selector === 'input' ? page.input : null;
  page.fire('load'); page.frames();
  assert.equal(page.html.children.length, 1); assert.equal(page.observers[0].off, true);
  assert.deepEqual(page.requests, []);
});
test('sandboxed (opaque-origin) frames get nothing at all', async () => {
  const page = contentPage({ origin: 'null' });
  vm.runInNewContext(await contentSource(), page.context);
  page.frames();
  assert.equal(page.html.children.length, 0); assert.deepEqual(page.events, {});
});
async function openContentMenu() {
  const page = contentPage();
  vm.runInNewContext(await contentSource(), page.context); page.frames();
  const host = page.html.children[0], button = host.root.children.find(node => node.tag === 'button');
  button.dispatch('click', { isTrusted: true, preventDefault() {} }); await settle();
  const frame = host.root.children.find(node => node.tag === 'iframe');
  return { page, host, button, frame };
}
test('content buttons reject synthetic clicks, use their own colour, and disclose only a token', async () => {
  const page = contentPage();
  vm.runInNewContext(await contentSource(), page.context); page.frames();
  const host = page.html.children[0], button = host.root.children.find(node => node.tag === 'button'); assert.ok(button);
  // The field's text is transparent (computed colour above); the button's colour comes from our stylesheet, keyed by background.
  assert.equal(button.style.color, undefined); assert.equal(button.dataset.tone, 'light');
  assert.match(host.root.children[0].textContent, /button\{[^}]*color:#6b6b70/);
  page.styles.set(page.input, { backgroundColor: 'rgb(20, 20, 24)' }); page.fire('toggle'); page.frames();
  assert.equal(button.dataset.tone, 'dark');
  button.dispatch('click', { isTrusted: false, preventDefault() {} }); await settle(); assert.deepEqual(page.requests, []);
  button.dispatch('click', { isTrusted: true, preventDefault() {} }); await settle();
  assert.deepEqual(JSON.parse(JSON.stringify(page.requests)), [{ type: 'openInlineMenu' }]);
  const frame = host.root.children.find(node => node.tag === 'iframe');
  assert.equal(frame.src, 'chrome-extension://self/inline.html#menu-token'); assert.equal(frame.title, 'inlineFrameTitle');
  assert.deepEqual([frame.style.width, frame.style.height], ['320px', '264px']);
  page.runtime({ type: 'closeInlineMenu', token: 'wrong' }); assert.equal(frame.isConnected, true);
  page.runtime({ type: 'closeInlineMenu', token: 'menu-token' }, { id: 'other' }); assert.equal(frame.isConnected, true);
  page.runtime({ type: 'closeInlineMenu', token: 'menu-token', refocus: true }); assert.equal(frame.isConnected, false);
  assert.equal(page.document.activeElement, page.input); assert.equal(page.requests.length, 1);
  assert.match(host.style.cssText, /width:0!important;height:0!important/);
  // An orphaned copy (extension updated or removed) removes its UI and never messages.
  page.context.chrome.runtime.id = undefined;
  page.fire('scroll'); page.frames();
  assert.equal(host.isConnected, false);
  button.dispatch('click', { isTrusted: true, preventDefault() {} }); await settle(); assert.equal(page.requests.length, 1);
});
test('the menu closes when its field or frame moves, its host is restyled, or its frame loads a second document', async () => {
  for (const [label, act] of [
    ['field moved', ({ page }) => { page.input.rect = { ...page.input.rect, top: 32, bottom: 72 }; }],
    ['frame moved', ({ frame }) => { frame.style.left = '40px'; }],
    ['host restyled', ({ host }) => { host.style.cssText += 'opacity:0'; }],
    ['second load', ({ frame }) => { frame.dispatch('load'); frame.dispatch('load'); }],
    ['replaced document', ({ frame }) => { frame.dispatch('load'); frame.contentDocument = { URL: 'about:blank' }; }]
  ]) {
    const opened = await openContentMenu();
    opened.page.frames(); assert.equal(opened.frame.isConnected, true, label);
    act(opened); opened.page.frames();
    assert.equal(opened.frame.isConnected, false, label);
    assert.deepEqual(JSON.parse(JSON.stringify(opened.page.requests.at(-1))), { type: 'closeInlineMenu', token: 'menu-token' }, label);
  }
});
test('outside pointerdown and Escape close the menu; Alt+Down opens it from the field', async () => {
  const { page, host, frame } = await openContentMenu();
  assert.equal(page.context.__keeforgeTouched, undefined);
  page.fire('keydown', { isTrusted: false, composedPath: () => [host] }); page.fire('focusin', { isTrusted: true, composedPath: () => [host] }); assert.equal(page.context.__keeforgeTouched, undefined);
  page.fire('pointerdown', { isTrusted: true, composedPath: () => [host] }); assert.equal(frame.isConnected, true);
  assert.equal(typeof page.context.__keeforgeTouched, 'number');
  page.fire('pointerdown', { isTrusted: true, composedPath: () => [page.document.body] }); assert.equal(frame.isConnected, false);
  page.fire('keydown', { isTrusted: true, key: 'ArrowDown', altKey: true, composedPath: () => [page.input], preventDefault() {} }); await settle();
  const second = host.root.children.filter(node => node.tag === 'iframe').at(-1);
  assert.notEqual(second, frame); assert.equal(second.isConnected, true);
  page.document.activeElement = null;
  page.fire('keydown', { isTrusted: true, key: 'Escape', composedPath: () => [] });
  assert.equal(second.isConnected, false); assert.equal(page.document.activeElement, page.input);
});

// A minimal DOM for running src/inline.js in a vm context.
class MenuNode {
  constructor(tag = 'div') { this.tag = tag; this.children = []; this.listeners = {}; this.dataset = {}; this.attributes = {}; this.style = {}; this.className = ''; this.hidden = false; }
  append(...nodes) { for (const node of nodes) node.parent = this; this.children.push(...nodes); }
  replaceChildren() { this.children = []; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(node => node !== this); }
  addEventListener(type, fn) { this.listeners[type] = fn; }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() {}
  all() { return this.children.flatMap(node => [node, ...node.all()]); }
  querySelectorAll(selector) { return this.all().filter(node => node.className.split(' ').includes(selector.slice(1))); }
}
async function menuPage({ supported = true, top = false, stateReply } = {}) {
  const source = (await readFile(new URL('../src/inline.js', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '');
  const rows = await import('../src/rows.js'), { groupsFor } = await import('../src/popup-state.js');
  const nodes = Object.fromEntries(['#status', '#content', '#site', '#viewport', '#state', '#state-icon', '#secure'].map(id => [id, new MenuNode()]));
  const content = nodes['#content'];
  const state = { callback: null, now: 0, requests: [], posted: [], listeners: {} };
  class Entry {}
  if (supported) Entry.prototype.isVisible = false;
  const window = { addEventListener() {} }; window.top = top ? window : {};
  const document = { visibilityState: 'visible', querySelector: selector => nodes[selector], createElement: tag => new MenuNode(tag), addEventListener: (type, fn) => { state.listeners[type] = fn; } };
  // rows.js runs in this module's realm; give it the same fake document and messages.
  globalThis.document = document; globalThis.chrome = { i18n: { getMessage: key => key } };
  const context = {
    message: key => key, reason: key => key, localizePage() {}, loginRow: rows.loginRow, renderGroups: rows.renderGroups, groupsFor,
    location: { hash: '#token' }, window, parent: { postMessage: (...args) => state.posted.push(args) }, URL, crypto,
    document, performance: { now: () => state.now }, IntersectionObserverEntry: Entry,
    IntersectionObserver: class { constructor(fn) { state.callback = fn; } observe() {} }, setInterval() {},
    chrome: { runtime: { sendMessage: async request => { state.requests.push(request); return request.action === 'state' ? stateReply ?? { ok: true, origin: 'https://example.com', entries: [{ entry: 'e', db: 'd', title: 'title', username: 'user', exact: true, hasTotp: false }], locked: 0 } : { ok: true }; } } }
  };
  vm.runInNewContext(source, context);
  const visible = (fields = {}) => state.callback([{ isIntersecting: true, boundingClientRect: { width: 300, height: 160 }, intersectionRect: { width: 300, height: 160 }, isVisible: true, ...fields }]);
  const fills = () => state.requests.filter(r => r.action === 'fill').length;
  const login = () => content.querySelectorAll('.kf-login')[0];
  return { state, content, visible, fills, login, context };
}
test('inline page gates trusted actions on the delay, complete intersection and visibility-v2 signal', async () => {
  const m = await menuPage();
  assert.equal(m.state.requests.length, 0);
  m.visible(); await settle();
  await m.login().listeners.click({ isTrusted: true }); assert.equal(m.fills(), 0);
  m.state.now = 400;
  await m.login().listeners.click({ isTrusted: false }); assert.equal(m.fills(), 0);
  m.state.now = 1000;
  // Continuously visible since 0, settled and trusted: only the isVisible signal can refuse this click.
  m.visible({ isVisible: false });
  await m.login().listeners.click({ isTrusted: true }); assert.equal(m.fills(), 0);
  m.visible({ intersectionRect: { width: 300, height: 157 } });
  await m.login().listeners.click({ isTrusted: true }); assert.equal(m.fills(), 0);
  m.visible(); await settle();
  // Becoming visible again restarts the continuous-visibility window.
  m.state.now = 1200; await m.login().listeners.click({ isTrusted: true }); assert.equal(m.fills(), 0);
  m.state.now = 1400; await m.login().listeners.click({ isTrusted: true }); assert.equal(m.fills(), 1);
  // Escape closes through the background; nothing is ever posted to the embedding page.
  m.state.listeners.keydown({ isTrusted: true, key: 'Escape' });
  assert.deepEqual(JSON.parse(JSON.stringify(m.state.requests.at(-1))), { type: 'inlineMenu', token: 'token', action: 'close', refocus: true });
  assert.deepEqual(m.state.posted, []);
  const top = await menuPage({ top: true });
  assert.equal(top.state.requests.length, 0);
});
test('inline page shows Unlock when the app answers locked, as it does with no database unlocked', async () => {
  const m = await menuPage({ stateReply: { ok: false, error: 'locked', origin: 'https://example.com' } });
  m.visible(); await settle();
  assert.equal(m.context.document.querySelector('#status').textContent, 'locked');
  assert.match(m.context.document.querySelector('#state-icon').className, /glyph-lock/);
  const unlock = m.content.querySelectorAll('.kf-primary')[0];
  assert.equal(unlock.textContent, 'unlock');
  m.state.now = 1000;
  await unlock.listeners.click({ isTrusted: true });
  assert.equal(m.state.requests.filter(r => r.action === 'unlock').length, 1);
});
test('inline page treats a sub-pixel clip as fully visible but not a real one', async () => {
  for (const [shownHeight, expected] of [[159.5, 1], [150, 0]]) {
    const m = await menuPage();
    m.visible({ intersectionRect: { width: 300, height: shownHeight } }); await settle();
    m.state.now = 1000;
    const login = m.login(); if (login) await login.listeners.click({ isTrusted: true });
    assert.equal(m.fills(), expected, `shown ${shownHeight}`);
  }
});
test('without visibility tracking a fill needs a second, delayed click on a confirm button', async () => {
  const m = await menuPage({ supported: false });
  m.visible(); await settle(); m.state.now = 1000;
  await m.login().listeners.click({ isTrusted: true });
  assert.equal(m.fills(), 0);
  const confirm = m.content.querySelectorAll('.kf-confirm')[0]?.children[0];
  assert.ok(confirm); assert.match(confirm.style.marginInlineStart, /^calc\(\(100% - 76px\) \* [0-9.]+\)$/);
  await confirm.listeners.click({ isTrusted: true }); assert.equal(m.fills(), 0);
  m.state.now = 1400; await confirm.listeners.click({ isTrusted: false }); assert.equal(m.fills(), 0);
  await confirm.listeners.click({ isTrusted: true }); assert.equal(m.fills(), 1);
  assert.deepEqual(m.state.posted, []);
});
test('Chrome keeps the one-click fill', async () => {
  const m = await menuPage();
  m.visible(); await settle(); m.state.now = 1000;
  await m.login().listeners.click({ isTrusted: true });
  assert.equal(m.fills(), 1); assert.equal(m.content.querySelectorAll('.kf-confirm').length, 0);
});
// Right-click fills: the browser's menu click is the only way to get a forced kind accepted.
function forcedSetup(kind, usable = true) {
  const s = setup(kind);
  s.api.contextMenus = { onClicked: new Event(), removed: 0, created: [], async removeAll() { this.removed++; this.created = []; }, create(properties, done) { this.created.push(properties); done(); } };
  s.api.runtime.getManifest = () => ({ content_scripts: [{ matches: ['https://*/*', 'http://localhost/*'] }] });
  s.api.i18n = { getMessage: key => key };
  const execute = s.api.scripting.executeScript;
  s.api.scripting.executeScript = async options => { const results = await execute(options); if (options.func === prepareInlineDocument) { assert.deepEqual(options.args, [kind]); results[0].result.usable = usable; } return results; };
  s.click = (menuItemId = { username: 'fill-username', password: 'fill-password', code: 'fill-code' }[kind], frameId = 3, frameUrl = 'https://frame.example/path') => s.b.contextClicked({ menuItemId, frameId, frameUrl }, { id: 7 });
  s.openForced = (forced = kind) => s.b.openMenu(s.sender, forced);
  return s;
}
test('a forced kind needs a browser menu click for that tab, frame, origin and kind, used once within ten seconds', async () => {
  let s = forcedSetup('password');
  await assert.rejects(s.openForced(), { code: 'target-required' });
  await s.click();
  assert.deepEqual(s.closed.at(-1), [7, { type: 'contextFill', kind: 'password' }, { frameId: 3 }]);
  assert.ok((await s.openForced()).token);
  await assert.rejects(s.openForced(), { code: 'target-required' });
  for (const [label, act] of [['wrong frame', s => s.click(undefined, 4)], ['wrong kind', s => s.click('fill-username')], ['other origin', s => s.click(undefined, 3, 'https://evil.example/')], ['expired', async s => { await s.click(); s.b.grants.get(7).expires = Date.now() - 1; }]]) {
    s = forcedSetup('password'); await act(s);
    await assert.rejects(s.openForced(), { code: 'target-required' }, label);
    assert.deepEqual(s.requests, []);
  }
  s = forcedSetup('password'); await s.b.contextClicked({ menuItemId: 'keeforge', frameId: 3 }, { id: 7 });
  assert.equal(s.b.grants.size, 0); assert.deepEqual(s.closed, []);
  s = forcedSetup('password'); await s.click();
  await assert.rejects(s.b.openMenu(s.sender, 'everything'), { code: 'bad-origin' });
});
test('a forced password session injects the password alone into the right-clicked field', async () => {
  const s = forcedSetup('password'); await s.click();
  const { token } = await s.openForced();
  assert.deepEqual(await s.call(token, 'fill', { entry: 'without-code', db: 'db' }), { ok: true });
  assert.deepEqual([s.fills[0].target.forced, s.fills[0].target.kind, s.fills[0].codeOnly], [true, 'password', false]);
  const { injectCredential } = await import('../src/fill.js');
  let args;
  await injectCredential({ scripting: { executeScript: async options => { args = options.args; return [{ frameId: 3, result: { password: true } }]; } } }, s.fills[0].target, { username: 'demo', password: 'secret' });
  assert.deepEqual([args[1], args[4], args[5]], [{ password: 'secret' }, 'forced', 'password']);
});
test('a forced code session lists only logins with a code and asks for the code alone', async () => {
  const s = forcedSetup('code'); await s.click();
  const { token } = await s.openForced();
  const state = await s.call(token, 'state');
  assert.deepEqual(state.entries.map(entry => entry.entry), ['with-code']);
  await s.call(token, 'fill', { entry: 'with-code', db: 'db' });
  assert.equal(s.requests.at(-1).fields.totp, true); assert.equal(s.fills[0].codeOnly, true);
});
test('a right-clicked field that cannot be filled gets a menu that explains it and does nothing else', async () => {
  const s = forcedSetup('username', false); await s.click();
  const { token } = await s.openForced();
  assert.deepEqual(await s.call(token, 'state'), { ok: false, error: 'field-unusable', origin: 'https://frame.example' });
  for (const action of ['fill', 'reveal', 'unlock', 'launchApp', 'pair']) await assert.rejects(s.call(token, action, { entry: 'without-code', db: 'db' }), { code: 'field-unusable' }, action);
  assert.deepEqual(s.requests, []); assert.deepEqual(s.fills, []);
});
test('the KeeForge context menu has three fill items on editable fields of the content-script sites', async () => {
  const s = forcedSetup('password');
  s.b.listen();
  await s.b.createContextMenus(); await s.b.createContextMenus();
  assert.equal(s.api.contextMenus.removed, 2);
  assert.deepEqual(s.api.contextMenus.created.map(item => [item.id, item.parentId, item.title]), [['keeforge', undefined, 'extensionName'], ['fill-username', 'keeforge', 'contextFillUsername'], ['fill-password', 'keeforge', 'contextFillPassword'], ['fill-code', 'keeforge', 'fillCode']]);
  for (const item of s.api.contextMenus.created) assert.deepEqual([item.contexts, item.documentUrlPatterns], [['editable'], ['https://*/*', 'http://localhost/*']]);
  assert.equal(s.api.contextMenus.onClicked.listeners.size, 1);
});
test('a right-click records the field; only the extension\'s own trusted menu message opens a forced menu', async () => {
  const page = contentPage();
  vm.runInNewContext(await contentSource(), page.context); page.frames();
  page.context.HTMLInputElement.prototype.matches = () => false;
  page.runtime({ type: 'contextFill', kind: 'password' }); await settle();
  assert.deepEqual(page.requests, []);
  page.fire('contextmenu', { isTrusted: false, clientX: 20, clientY: 40, composedPath: () => [page.input] });
  page.runtime({ type: 'contextFill', kind: 'username' }); await settle();
  assert.deepEqual(page.requests, []);
  page.fire('contextmenu', { isTrusted: true, clientX: 20, clientY: 40, composedPath: () => [page.input] });
  page.runtime({ type: 'contextFill', kind: 'username' }, { id: 'other' }); page.runtime({ type: 'contextFill', kind: 'everything' }); await settle();
  assert.deepEqual(page.requests, []);
  page.runtime({ type: 'contextFill', kind: 'username' }); await settle();
  assert.deepEqual(JSON.parse(JSON.stringify(page.requests)), [{ type: 'openInlineMenu', forced: 'username' }]);
  assert.equal(page.context.__keeforgeInlineField, page.input);
  page.fire('pagehide'); page.requests.length = 0;
  page.runtime({ type: 'contextFill', kind: 'username' }); await settle();
  assert.deepEqual(page.requests, []);
});
