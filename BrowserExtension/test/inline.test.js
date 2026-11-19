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
  assert.deepEqual(s.closed[0], [7, { type: 'closeInlineMenu', token: first.token }, { frameId: 3, documentId: 'doc' }]);
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
test('classic content script contains the exact shared fill function and never messages on discovery', async () => {
  const source = await readFile(new URL('../src/content.js', import.meta.url), 'utf8');
  assert.equal(source.split('// BEGIN shared fillDocument\n')[1].split('\n// END shared fillDocument')[0], fillDocument.toString());
  const requests = [], frames = [], listeners = {};
  const node = () => ({ style: {}, append() {}, attachShadow: node });
  const document = { documentElement: node(), body: {}, createElement: node, createTreeWalker: () => ({ nextNode: () => null }), hasFocus: () => true };
  const context = { document, location: { href: 'https://example.com' }, chrome: { runtime: { id: 'self', getURL: path => 'chrome-extension://self/' + path, onMessage: { addListener() {} }, sendMessage: request => { requests.push(request); return Promise.resolve({}); } } }, MutationObserver: class { observe() {} disconnect() {} }, setInterval: callback => frames.push(callback), setTimeout() {}, addEventListener: (name, callback) => { listeners[name] = callback; }, requestAnimationFrame: callback => frames.push(callback), performance: { now: () => 1000 }, NodeFilter: { SHOW_ELEMENT: 1 }, HTMLInputElement: class {} };
  vm.runInNewContext(source, context);
  frames.shift()(); frames.shift()();
  listeners.resize(); listeners.scroll();
  assert.deepEqual(requests, []);
  assert.ok(!/^import /m.test(source));
});
test('inline page gates trusted actions on the delay, complete intersection and visibility-v2 signal', async () => {
  const { groupsFor } = await import('../src/popup-state.js');
  const source = (await readFile(new URL('../src/inline.js', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '');
  for (const supported of [true, false]) {
    class Node {
      constructor() { this.children = []; this.listeners = {}; this.classList = { add() {}, remove() {} }; }
      append(...nodes) { this.children.push(...nodes); }
      replaceChildren() { this.children = []; }
      addEventListener(type, fn) { this.listeners[type] = fn; }
      setAttribute() {}
      getBoundingClientRect() { return { height: 30 }; }
      querySelectorAll() { return this.children.flatMap(n => [...(n.listeners.click ? [n] : []), ...n.querySelectorAll()]); }
    }
    const status = new Node(), content = new Node(), site = new Node(), main = new Node(); main.children = [status, content];
    let callback, now = 0; const requests = [];
    const window = { top: {}, addEventListener() {} };
    class Entry {}
    if (supported) Entry.prototype.isVisible = false;
    const context = {
      message: key => key, reason: key => key, localizePage() {}, groupsFor,
      location: { hash: '#token' }, window, parent: { postMessage() {} }, URL,
      document: { visibilityState: 'visible', querySelector: selector => ({ '#status': status, '#content': content, '#site': site, '#viewport': main, '#sizer': main })[selector], createElement: () => new Node(), createElementNS: () => new Node(), addEventListener() {} },
      performance: { now: () => now }, IntersectionObserverEntry: Entry,
      IntersectionObserver: class { constructor(fn) { callback = fn; } observe() {} }, setInterval() {},
      chrome: { runtime: { sendMessage: async request => { requests.push(request); return request.action === 'state' ? { ok: true, origin: 'https://example.com', entries: [{ entry: 'e', db: 'd', title: 'title', username: 'user', exact: true, hasTotp: false }], locked: 0 } : { ok: false, error: 'denied' }; } } }
    };
    vm.runInNewContext(source, context);
    assert.equal(requests.length, 0);
    callback([{ isIntersecting: true, boundingClientRect: { width: 300, height: 30 }, intersectionRect: { width: 300, height: 30 }, isVisible: true }]);
    await new Promise(resolve => setImmediate(resolve));
    const login = content.children[0].children[0];
    await login.listeners.click({ isTrusted: true }); assert.equal(requests.filter(r => r.action === 'fill').length, 0);
    now = 400;
    await login.listeners.click({ isTrusted: false }); assert.equal(requests.filter(r => r.action === 'fill').length, 0);
    callback([{ isIntersecting: true, boundingClientRect: { width: 300, height: 30 }, intersectionRect: { width: 300, height: 27 }, isVisible: true }]);
    await login.listeners.click({ isTrusted: true }); assert.equal(requests.filter(r => r.action === 'fill').length, 0);
    callback([{ isIntersecting: true, boundingClientRect: { width: 300, height: 30 }, intersectionRect: { width: 300, height: 30 }, isVisible: false }]);
    await new Promise(resolve => setImmediate(resolve));
    if (supported) { await login.listeners.click({ isTrusted: true }); assert.equal(requests.filter(r => r.action === 'fill').length, 0); }
    callback([{ isIntersecting: true, boundingClientRect: { width: 300, height: 30 }, intersectionRect: { width: 300, height: 30 }, isVisible: true }]);
    await new Promise(resolve => setImmediate(resolve));
    // Becoming visible again restarts the continuous-visibility window.
    now = 600; await login.listeners.click({ isTrusted: true }); assert.equal(requests.filter(r => r.action === 'fill').length, 0);
    now = 1000; await login.listeners.click({ isTrusted: true }); assert.equal(requests.filter(r => r.action === 'fill').length, 1);
    // A top-level document must not even ask for state with a forged token.
    context.window.top = context.window; requests.length = 0;
    vm.runInNewContext(source, { ...context });
    assert.equal(requests.length, 0);
  }
});
test('content buttons reject synthetic clicks, disclose only a token, and validate iframe size messages', async () => {
  const source = await readFile(new URL('../src/content.js', import.meta.url), 'utf8');
  const callbacks = [], events = {}, requests = [], rootChildren = [];
  class Node {
    constructor(tag) { this.tag = tag; this.style = {}; this.listeners = {}; this.children = []; this.isConnected = true; }
    append(...nodes) { this.children.push(...nodes); }
    attachShadow() { return this.root = new Node('shadow'); }
    setAttribute() {}
    addEventListener(type, fn) { this.listeners[type] = fn; }
    remove() { this.isConnected = false; }
  }
  class Input extends Node {
    type = 'text'; autocomplete = 'username';
    getBoundingClientRect() { return { left: 10, right: 250, top: 30, bottom: 70, width: 240, height: 40 }; }
    getClientRects() { return [this.getBoundingClientRect()]; }
    matches() { return false; }
    focus() { document.activeElement = this; }
  }
  const input = new Input('input');
  const document = { documentElement: new Node('html'), body: new Node('body'), activeElement: null, hasFocus: () => true, createElement: tag => { const node = new Node(tag); if (tag === 'iframe') node.contentWindow = {}; rootChildren.push(node); return node; }, querySelectorAll: () => [input], createTreeWalker: () => { const nodes = [input]; return { nextNode: () => nodes.shift() }; } };
  input.ownerDocument = document;
  let runtimeListener;
  const context = { document, HTMLInputElement: Input, NodeFilter: { SHOW_ELEMENT: 1 }, innerWidth: 800, innerHeight: 600, getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1', direction: 'ltr' }), crypto,
    location: { href: 'https://example.com' }, origin: 'https://example.com', performance: { now: () => 1000 }, MutationObserver: class { observe() {} disconnect() {} }, setInterval() {}, clearInterval() {}, setTimeout() {}, clearTimeout() {}, requestAnimationFrame: callback => callbacks.push(callback), addEventListener: (type, fn) => { events[type] = fn; }, chrome: { i18n: { getMessage: () => 'localized button name' }, runtime: { id: 'self', getURL: path => 'chrome-extension://self/' + path, onMessage: { addListener: fn => { runtimeListener = fn; } }, sendMessage: async request => { requests.push(request); return { token: 'menu-token' }; } } } };
  vm.runInNewContext(source, context); callbacks.shift()();
  const button = rootChildren.find(node => node.tag === 'button'); assert.ok(button);
  assert.deepEqual(requests, []);
  button.listeners.click({ isTrusted: false, preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve)); assert.deepEqual(requests, []);
  button.listeners.click({ isTrusted: true, preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests.length, 1); assert.deepEqual(JSON.parse(JSON.stringify(requests[0])), { type: 'openInlineMenu' });
  const frame = rootChildren.find(node => node.tag === 'iframe'); assert.equal(frame.src, 'chrome-extension://self/inline.html#menu-token');
  const before = frame.style.height;
  for (const event of [
    { source: {}, origin: 'chrome-extension://self', data: { type: 'inlineSize', height: 100 } },
    { source: frame.contentWindow, origin: 'https://evil.example', data: { type: 'inlineSize', height: 100 } },
    { source: frame.contentWindow, origin: 'chrome-extension://self', data: { type: 'inlineSize', height: 900 } }
  ]) events.message(event);
  assert.equal(frame.style.height, before);
  events.message({ source: frame.contentWindow, origin: 'chrome-extension://self', data: { type: 'inlineSize', height: 100 } });
  assert.equal(frame.style.height, '100px');
  runtimeListener({ type: 'closeInlineMenu', token: 'wrong' }); assert.equal(frame.isConnected, true);
  runtimeListener({ type: 'closeInlineMenu', token: 'menu-token' }); assert.equal(frame.isConnected, false);
  assert.equal(requests.length, 1);
  // A viewport-sized host would occlude child frames' menus for visibility tracking.
  const host = document.documentElement.children[0];
  assert.match(host.style.cssText, /width:0!important;height:0!important/); assert.doesNotMatch(host.style.cssText, /inset/);
  // An orphaned copy (extension updated or removed) removes its UI and never messages.
  context.chrome.runtime.id = undefined;
  events.scroll({}); callbacks.shift()();
  assert.equal(host.isConnected, false);
  button.listeners.click({ isTrusted: true, preventDefault() {} });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(requests.length, 1);
});
test('inline page treats a sub-pixel clip as fully visible but not a real one', async () => {
  const { groupsFor } = await import('../src/popup-state.js');
  const source = (await readFile(new URL('../src/inline.js', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '');
  class Node {
    constructor() { this.children = []; this.listeners = {}; this.classList = { add() {}, remove() {} }; }
    append(...nodes) { this.children.push(...nodes); }
    replaceChildren() { this.children = []; }
    addEventListener(type, fn) { this.listeners[type] = fn; }
    setAttribute() {}
    getBoundingClientRect() { return { height: 30 }; }
    querySelectorAll() { return this.children.flatMap(n => [...(n.listeners.click ? [n] : []), ...n.querySelectorAll()]); }
  }
  for (const [shownHeight, expected] of [[159.5, 1], [150, 0]]) {
    const content = new Node(), nodes = { '#status': new Node(), '#content': content, '#site': new Node(), '#viewport': new Node(), '#sizer': new Node() };
    let callback, now = 0; const requests = [];
    class Entry {} Entry.prototype.isVisible = false;
    vm.runInNewContext(source, {
      message: key => key, reason: key => key, localizePage() {}, groupsFor, location: { hash: '#token' }, window: { top: {}, addEventListener() {} }, parent: { postMessage() {} }, URL,
      document: { visibilityState: 'visible', querySelector: selector => nodes[selector], createElement: () => new Node(), createElementNS: () => new Node(), addEventListener() {} },
      performance: { now: () => now }, IntersectionObserverEntry: Entry, IntersectionObserver: class { constructor(fn) { callback = fn; } observe() {} }, setInterval() {},
      chrome: { runtime: { sendMessage: async request => { requests.push(request); return request.action === 'state' ? { ok: true, origin: 'https://example.com', entries: [{ entry: 'e', db: 'd', title: 't', username: 'u', exact: true, hasTotp: false }], locked: 0 } : { ok: true }; } } }
    });
    callback([{ isIntersecting: true, boundingClientRect: { width: 320, height: 160 }, intersectionRect: { width: 320, height: shownHeight }, isVisible: true }]);
    await new Promise(resolve => setImmediate(resolve));
    now = 1000;
    const login = content.children[0]?.children[0];
    if (login) await login.listeners.click({ isTrusted: true });
    assert.equal(requests.filter(r => r.action === 'fill').length, expected, `shown ${shownHeight}`);
  }
});
