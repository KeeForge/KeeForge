import test from 'node:test';
import assert from 'node:assert/strict';
import { fillDocument, injectCredential } from '../src/fill.js';
import { probeFrame } from '../src/frames.js';
class Input {
  constructor({ type = 'text', autocomplete = '', form = null, ...properties } = {}) { Object.assign(this, { type, autocomplete, form, clientLeft: 0, clientTop: 0, clientWidth: 90, clientHeight: 20, events: [], box: { top: 10, left: 10, bottom: 30, right: 100, width: 90, height: 20 }, style: { display: 'block', visibility: 'visible', opacity: '1' } }, properties); }
  set value(value) { this.nativeValue = value; }
  get value() { return this.nativeValue; }
  getBoundingClientRect() { return this.box; }
  getClientRects() { return this.hidden ? [] : [this.box]; }
  matches() { return false; }
  dispatchEvent(event) { this.events.push([event.type, event.bubbles]); this.onEvent?.(event); }
}
function page(fields, focused = null) {
  Object.assign(globalThis, { location: { origin: 'https://example.com' }, origin: 'https://example.com', innerWidth: 1000, innerHeight: 800, HTMLInputElement: Input, getComputedStyle: input => input.style, document: { querySelectorAll: () => fields, activeElement: focused, hasFocus: () => true, submit: () => assert.fail('must not submit') } });
  for (const input of fields) { input.ownerDocument = document; input.isConnected ??= true; }
  probeFrame();
}
const credential = { username: 'demo', password: 'secret', totp: '123456' };
const fill = (codeOnly = false) => fillDocument('https://example.com', credential, codeOnly, globalThis.__keeforgeDocumentPin);
test('nearest preceding visible same-form username, password, native setter and events; never submit', () => {
  const form = { submit: () => assert.fail('must not submit'), requestSubmit: () => assert.fail('must not submit') };
  const wrongForm = new Input({ form: {} }), first = new Input({ form }), user = new Input({ type: 'email', form }), pass = new Input({ type: 'password', form });
  Object.defineProperty(user, 'value', { set() { assert.fail('framework setter used'); } });
  page([wrongForm, first, user, pass]);
  assert.deepEqual(fill(), { username: true, password: true, totp: false }); assert.equal(user.nativeValue, 'demo'); assert.equal(pass.value, 'secret'); assert.equal(first.value, undefined); assert.equal(wrongForm.value, undefined);
  for (const input of [user, pass]) assert.deepEqual(input.events, [['input', true], ['change', true]]);
});
test('focused field wins; autocomplete username and current-password precede heuristics', () => {
  const named = new Input({ autocomplete: 'section-login username' }), focused = new Input(), old = new Input({ type: 'password' }), current = new Input({ type: 'password', autocomplete: 'current-password' });
  page([named, focused, old, current], focused); fill(); assert.equal(focused.value, 'demo'); assert.equal(named.value, undefined); assert.equal(current.value, 'secret'); assert.equal(old.value, undefined);
  page([named, old, current], old); fill(); assert.equal(old.value, 'secret'); assert.equal(named.value, 'demo');
});
test('focused form confines selection and unrelated forms are untouched', () => {
  const wrong = new Input({ type: 'password', form: {} }), form = {}, user = new Input({ form }), password = new Input({ type: 'password', form });
  page([wrong, user, password], user); fill(); assert.equal(wrong.value, undefined); assert.equal(password.value, 'secret');
});
test('skip hidden, disabled, read-only, off-screen and CSS-hidden fields', () => {
  for (const properties of [{ hidden: true }, { disabled: true }, { readOnly: true }, { type: 'hidden' }, { box: { top: 900, bottom: 920, left: 0, right: 10, width: 10, height: 20 } }, { style: { display: 'none' } }, { style: { visibility: 'hidden' } }, { style: { opacity: '0' } }]) {
    const input = new Input(properties); page([input], input); assert.deepEqual(fill(true), { username: false, password: false, totp: false }); assert.equal(input.value, undefined);
  }
});
test('code prefers one-time-code, otherwise focused field; no password or username in code mode', () => {
  const user = new Input(), pass = new Input({ type: 'password' }), code = new Input({ autocomplete: 'one-time-code' });
  page([user, pass, code], user); assert.deepEqual(fill(true), { username: false, password: false, totp: true }); assert.equal(code.value, '123456'); assert.equal(user.value, undefined); assert.equal(pass.value, undefined);
  page([user, pass], user); fill(true); assert.equal(user.value, '123456');
});
test('changed or opaque origin refuses before accessing DOM', () => {
  page([]); document.querySelectorAll = () => assert.fail('DOM accessed');
  for (const value of ['https://elsewhere.example', 'null']) { location.origin = value; assert.deepEqual(fill(), { username: false, password: false, totp: false }); }
});
test('injection targets one document or legacy Firefox frame; sends only requested fields and returns no credential', async () => {
  for (const documentId of ['document', undefined]) {
    let call;
    const api = { scripting: { executeScript: async options => { call = options; return [{ frameId: 2, result: { totp: true } }]; } } };
    assert.equal(await injectCredential(api, { tabId: 1, frameId: 2, documentId, origin: 'https://example.com', token: 'pin' }, credential, true), undefined);
    assert.deepEqual(call.target, documentId ? { tabId: 1, documentIds: ['document'] } : { tabId: 1, frameIds: [2] }); assert.equal(call.world, 'ISOLATED'); assert.deepEqual(call.args, ['https://example.com', { totp: '123456' }, true, 'pin']);
  }
  await assert.rejects(injectCredential({ scripting: { executeScript: async () => [{ frameId: 2, result: { username: false, password: false, totp: false } }] } }, { tabId: 1, frameId: 2 }, credential), /no-fields/);
});
test('numeric verification code, disabled fieldset, transparent ancestor and non-editable input types', () => {
  const code = new Input({ type: 'number', autocomplete: 'one-time-code' }); page([code]); assert.equal(fill(true).totp, true); assert.equal(code.value, '123456');
  for (const properties of [{ matches: selector => selector === ':disabled' }, { parentElement: new Input({ style: { opacity: '0' } }) }, { type: 'checkbox' }, { type: 'file' }]) {
    const input = new Input(properties); page([input], input); assert.equal(fill(true).totp, false); assert.equal(input.value, undefined);
  }
});
test('a focused form-less field does not pull a password from an unrelated form', () => {
  const user = new Input(), password = new Input({ type: 'password', form: {} });
  page([user, password], user); assert.deepEqual(fill(), { username: true, password: false, totp: false }); assert.equal(password.value, undefined);
});

test('frame probe reports focus, fillability and an opaque token, never location or values', () => {
  const input = new Input({ type: 'number', autocomplete: 'one-time-code' });
  page([input], input); document.hasFocus = () => true;
  assert.equal(probeFrame().focused, true); assert.equal(probeFrame().fillable, true);
  document.hasFocus = () => false; assert.equal(probeFrame().focused, false); assert.equal(probeFrame().fillable, true);
  input.disabled = true; assert.equal(probeFrame().focused, false); assert.equal(probeFrame().fillable, false);
});

test('password autocomplete on text never qualifies for the password write', () => {
  const user = new Input(), trap = new Input({ autocomplete: 'current-password' }), fresh = new Input({ autocomplete: 'new-password' }), password = new Input({ type: 'password' });
  page([user, trap, fresh, password]); fill();
  assert.equal(trap.value, undefined); assert.equal(fresh.value, undefined); assert.equal(user.value, credential.username); assert.equal(password.value, credential.password);
});
test('password target is rechecked after username handlers; no further writes on failure', () => {
  for (const mutate of [p => { p.type = 'text'; }, p => { p.hidden = true; }, p => { p.isConnected = false; }, p => { p.ownerDocument = {}; }, p => { p.style.clipPath = 'inset(100%)'; }]) {
    const password = new Input({ type: 'password' });
    const user = new Input({ autocomplete: 'username', onEvent: event => { if (event.type === 'input') mutate(password); } });
    page([user, password]); const result = fill();
    assert.deepEqual(result, { username: false, password: false, totp: false }); assert.equal(password.value, undefined); assert.deepEqual(password.events, []);
  }
});
test('username and code also recheck type, visibility, connection and owner before write', () => {
  for (const codeOnly of [false, true]) for (const mutate of [p => { p.type = 'password'; }, p => { p.hidden = true; }, p => { p.isConnected = false; }, p => { p.ownerDocument = {}; }]) {
    const input = new Input(), password = new Input({ type: 'password' });
    page([input, password], input);
    Object.defineProperty(input, 'autocomplete', { get() { mutate(input); return codeOnly ? 'one-time-code' : 'username'; } });
    const result = fill(codeOnly);
    assert.equal(input.value, undefined); assert.equal(password.value, undefined);
    assert.equal(result[codeOnly ? 'totp' : 'username'], false);
  }
});
test('probe and fill share conservative visibility table for fields and ancestors', () => {
  const hidden = [
    { style: { clipPath: 'inset(100%)' } }, { style: { clip: 'rect(0px, 0px, 0px, 0px)' } },
    { style: { maskImage: 'linear-gradient(transparent, transparent)' } }, { style: { webkitMaskImage: 'url(mask.svg)' } },
    { style: { visibility: 'hidden' } }, { style: { contentVisibility: 'hidden' } }, { inert: true }, { localName: 'details', open: false },
    { box: { top: 0, left: 0, bottom: 0, right: 0, width: 0, height: 0 } }
  ];
  for (const ancestor of [false, true]) for (const properties of hidden) {
    const input = new Input({ type: 'password', ...(ancestor ? { parentElement: new Input(properties) } : properties) });
    page([input], input);
    assert.equal(probeFrame().fillable, false, JSON.stringify({ ancestor, properties }));
    assert.equal(fill().password, false); assert.equal(input.value, undefined);
  }
  for (const overflow of ['hidden', 'clip', 'auto', 'scroll']) {
    const ancestor = new Input({ style: { overflow }, box: { left: 200, right: 300, top: 200, bottom: 300, width: 100, height: 100 } });
    const input = new Input({ type: 'password', parentElement: ancestor }); page([input], input);
    assert.equal(probeFrame().fillable, false); assert.equal(fill().password, false); assert.equal(input.value, undefined);
  }
  const bordered = new Input({ type: 'password', parentElement: new Input({ style: { overflow: 'hidden' }, clientWidth: 0, clientHeight: 0 }) }); page([bordered]);
  assert.equal(probeFrame().fillable, false); assert.equal(fill().password, false);
  const visible = new Input({ type: 'password', parentElement: new Input({ style: { overflow: 'hidden' } }) }); page([visible]);
  assert.equal(probeFrame().fillable, true); assert.equal(fill().password, true);
});
test('document token is random per selection; fill rejects absent or replaced token even at same origin', () => {
  const input = new Input({ type: 'password' }); page([input]);
  const first = probeFrame().token, second = probeFrame().token;
  assert.match(first, /^[0-9a-f]{64}$/); assert.notEqual(first, second);
  for (const token of [undefined, first, 'wrong']) assert.equal(fillDocument('https://example.com', credential, false, token).password, false);
  delete globalThis.__keeforgeDocumentPin;
  assert.equal(fillDocument('https://example.com', credential, false, second).password, false); assert.equal(input.value, undefined);
});
test('serialized probe and fill traverse nested open shadow roots and deepest focus', () => {
  const user = new Input({ autocomplete: 'username' }), password = new Input({ type: 'password' });
  const outside = new Input({ type: 'password', form: {} }); page([user, password, outside]);
  const host = new Input(), inner = new Input();
  host.shadowRoot = { activeElement: inner, querySelectorAll: () => [inner] };
  inner.shadowRoot = { activeElement: user, querySelectorAll: () => [user, password] };
  user.getRootNode = password.getRootNode = () => ({ host: inner }); inner.getRootNode = () => ({ host });
  document.querySelectorAll = () => [outside, host]; document.activeElement = host;
  const serialized = (0, eval)(`(${fillDocument.toString()})`);
  const probe = serialized(); assert.equal(probe.focused, true); assert.equal(probe.fillable, true);
  assert.equal(serialized('https://example.com', credential, false, probe.token).password, true);
  assert.equal(user.value, credential.username); assert.equal(password.value, credential.password); assert.equal(outside.value, undefined);
  host.inert = true; assert.equal(serialized().focused, false);
});
test('body and root overflow belongs to the viewport, so a short scroll-locked body does not clip a visible field', () => {
  const short = { left: 0, right: 1000, top: 0, bottom: 40, width: 1000, height: 40 };
  const html = new Input({ style: { overflow: 'visible', overflowX: 'visible', overflowY: 'visible', contain: 'none' }, box: short, clientHeight: 40 });
  const body = new Input({ style: { overflow: 'hidden', overflowX: 'hidden', overflowY: 'hidden', contain: 'none' }, box: short, clientHeight: 40, parentElement: html });
  const password = new Input({ type: 'password', box: { top: 400, bottom: 420, left: 10, right: 100, width: 90, height: 20 }, parentElement: body });
  page([password]); Object.assign(document, { documentElement: html, body });
  assert.equal(probeFrame().fillable, true); assert.equal(fill().password, true);
  for (const change of [() => { html.style.overflowY = 'hidden'; }, () => { body.style.contain = 'paint'; }]) {
    html.style.overflowY = 'visible'; body.style.contain = 'none'; change();
    assert.equal(probeFrame().fillable, false);
  }
});
