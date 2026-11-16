import test from 'node:test';
import assert from 'node:assert/strict';
import { fillDocument, injectCredential } from '../src/fill.js';
import { probeFrame } from '../src/frames.js';
class Input {
  constructor({ type = 'text', autocomplete = '', form = null, ...properties } = {}) { Object.assign(this, { type, autocomplete, form, events: [], box: { top: 10, left: 10, bottom: 30, right: 100, width: 90, height: 20 }, style: { display: 'block', visibility: 'visible', opacity: '1' } }, properties); }
  set value(value) { this.nativeValue = value; }
  get value() { return this.nativeValue; }
  getBoundingClientRect() { return this.box; }
  getClientRects() { return this.hidden ? [] : [this.box]; }
  dispatchEvent(event) { this.events.push([event.type, event.bubbles]); }
}
function page(fields, focused = null) {
  Object.assign(globalThis, { location: { origin: 'https://example.com' }, origin: 'https://example.com', innerWidth: 1000, innerHeight: 800, HTMLInputElement: Input, getComputedStyle: input => input.style, document: { querySelectorAll: () => fields, activeElement: focused, submit: () => assert.fail('must not submit') } });
}
const credential = { username: 'demo', password: 'secret', totp: '123456' };
const fill = (codeOnly = false) => fillDocument('https://example.com', credential, codeOnly);
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
    assert.equal(await injectCredential(api, { tabId: 1, frameId: 2, documentId, origin: 'https://example.com' }, credential, true), undefined);
    assert.deepEqual(call.target, documentId ? { tabId: 1, documentIds: ['document'] } : { tabId: 1, frameIds: [2] }); assert.equal(call.world, 'ISOLATED'); assert.deepEqual(call.args, ['https://example.com', { totp: '123456' }, true]);
  }
  await assert.rejects(injectCredential({ scripting: { executeScript: async () => [{ frameId: 2, result: { username: false, password: false, totp: false } }] } }, { tabId: 1, frameId: 2 }, credential), /no-fields/);
});
test('numeric verification code, disabled fieldset, transparent ancestor and non-editable input types', () => {
  const code = new Input({ type: 'number', autocomplete: 'one-time-code' }); page([code]); assert.equal(fill(true).totp, true); assert.equal(code.value, '123456');
  for (const properties of [{ matches: selector => selector === ':disabled' }, { parentElement: { style: { opacity: '0' } } }, { type: 'checkbox' }, { type: 'file' }]) {
    const input = new Input(properties); page([input], input); assert.equal(fill(true).totp, false); assert.equal(input.value, undefined);
  }
});
test('a focused form-less field does not pull a password from an unrelated form', () => {
  const user = new Input(), password = new Input({ type: 'password', form: {} });
  page([user, password], user); assert.deepEqual(fill(), { username: true, password: false, totp: false }); assert.equal(password.value, undefined);
});

test('frame probe reports only focus and editable-field booleans, never location or values', () => {
  const input = new Input({ type: 'number', autocomplete: 'one-time-code' });
  page([input], input); document.hasFocus = () => true;
  assert.deepEqual(probeFrame(), { focused: true, fillable: true });
  document.hasFocus = () => false; assert.deepEqual(probeFrame(), { focused: false, fillable: true });
  input.disabled = true; assert.deepEqual(probeFrame(), { focused: false, fillable: false });
});
