import test from 'node:test';
import assert from 'node:assert/strict';
import { PopupState, groupsFor } from '../src/popup-state.js';
import { chooseFrame } from '../src/frames.js';
const entry = (id, exact = true, db = 'a') => ({ entry: id, db, dbName: db.toUpperCase(), title: id, username: 'user', hasTotp: true, exact });
test('popup states cover background states, match replies and failures', () => {
  const model = new PopupState(() => assert.fail());
  for (const state of ['host-missing', 'app-unavailable', 'unpaired', 'pairing', 'ready', 'error']) { model.reply({ state, reason: 'timeout' }); assert.equal(model.state, state); }
  for (const [reply, state] of [[{ ok: false, error: 'locked' }, 'locked'], [{ ok: true, entries: [], locked: 2 }, 'locked'], [{ ok: true, entries: [], locked: 0 }, 'empty'], [{ ok: true, entries: [entry('1')], locked: 2 }, 'matches'], [{ ok: false, error: 'timeout' }, 'error'], [{ ok: false, error: 'no-match' }, 'error'], [{}, 'error']]) { model.reply(reply); assert.equal(model.state, state); }
});
test('exact before possible, grouped by database only when multiple databases', () => {
  const entries = [entry('possible-b', false, 'b'), entry('exact-b', true, 'b'), entry('possible-a', false), entry('exact-a')];
  const groups = groupsFor(entries);
  assert.deepEqual(groups.map(g => [g.exact, g.name, g.entries[0].entry]), [[true, 'A', 'exact-a'], [true, 'B', 'exact-b'], [false, 'A', 'possible-a'], [false, 'B', 'possible-b']]);
  assert.equal(groupsFor([entry('1'), entry('2')])[0].name, null);
});
test('keyboard selection, pending confirmation, id-only fill, success clears all metadata', async () => {
  let finish; const calls = [];
  const model = new PopupState(request => { calls.push(request); return new Promise(resolve => { finish = resolve; }); });
  model.target = { tabId: 1, frameId: 3, origin: 'https://example.com' };
  model.reply({ entries: [entry('1'), entry('2')], locked: 0 });
  assert.equal(model.selected, 0); model.move('ArrowUp'); assert.equal(model.selected, 1); model.move('ArrowDown'); assert.equal(model.selected, 0);
  const filling = model.fill();
  assert.equal(model.state, 'confirm'); assert.equal(await model.fill(), false);
  assert.deepEqual(calls, [{ type: 'fill', tabId: 1, frameId: 3, token: undefined, entry: '1', db: 'a' }]);
  finish({ ok: true }); assert.equal(await filling, true);
  assert.deepEqual(model.entries, []); assert.equal(model.target, null); assert.equal(model.state, 'done');
});
test('code fills request only ids plus code flag and failure leaves no rows', async () => {
  const model = new PopupState(async request => { assert.deepEqual(request, { type: 'fill', tabId: 7, frameId: 0, token: undefined, entry: '1', db: 'a', totp: true }); return { ok: false, error: 'no-match' }; });
  model.target = { tabId: 7, frameId: 0 }; model.reply({ entries: [entry('1')], locked: 0 });
  assert.equal(await model.fill(0, true), false); assert.equal(model.state, 'error'); assert.equal(model.error, 'no-match'); assert.deepEqual(model.entries, []);
});
test('frame choice table: focused fillable frame, otherwise top, ignoring errors and unfocused children', () => {
  const p = (frameId, focused, fillable) => ({ frameId, result: { focused, fillable } });
  for (const [probes, expected] of [[[], 0], [[p(0,false,true), p(2,false,true)],0], [[p(0,false,false),p(2,true,true)],2], [[p(0,false,true),p(2,true,false)],0], [[p(0,true,true),p(2,false,true)],0], [[{...p(2,true,true),error:'denied'}],0]]) assert.equal(chooseFrame(probes), expected);
});
test('fill rejection becomes a readable error, clears rows, and never closes successfully', async () => {
  const model = new PopupState(async () => { throw new Error('disconnected'); });
  model.target = { tabId: 1, frameId: 0 }; model.reply({ entries: [entry('1')], locked: 0 });
  assert.equal(await model.fill(), false); assert.equal(model.state, 'error'); assert.deepEqual(model.entries, []);
});

test('lost pin reruns target selection from scratch before displaying rows', async () => {
  const calls = []; let selection = 0;
  const model = new PopupState(async request => {
    calls.push(request);
    if (request.type === 'getState') return { state: 'ready' };
    if (request.type === 'getTarget') return { tabId: 1, frameId: 0, token: `pin${++selection}` };
    assert.equal(model.entries.length, 0);
    return selection === 1 ? { ok: false, error: 'target-required' } : { entries: [entry('new')], locked: 0 };
  });
  await model.load();
  assert.deepEqual(calls.map(c => c.type), ['getState', 'getTarget', 'getMatches', 'getTarget', 'getMatches']);
  assert.equal(calls[0].reconnect, true); assert.equal(model.target.token, 'pin2'); assert.equal(model.entries[0].entry, 'new');
});
test('retry clears stale target and rows; repeated lost pins leave no actionable target', async () => {
  const model = new PopupState(async request => request.type === 'getState' ? { state: 'ready' } : request.type === 'getTarget' ? { tabId: 1, frameId: 0, token: 'pin' } : { ok: false, error: 'target-required' });
  model.target = { tabId: 9 }; model.reply({ entries: [entry('stale')] });
  await model.load(); assert.equal(model.state, 'error'); assert.equal(model.target, null); assert.deepEqual(model.entries, []); assert.equal(await model.fill(), false);
});

test('popup renders localized Try Again and its click reruns selection before showing rows', async () => {
  const { until } = await import('./fakes.js');
  class Node {
    constructor(tag = '') { this.tag = tag; this.children = []; this.listeners = {}; this.dataset = {}; this.attributes = {}; }
    querySelectorAll(selector) { return this.children.flatMap(child => [...(selector === '.kf-row' && child.className === 'kf-row' ? [child] : []), ...child.querySelectorAll(selector)]); }
    append(...children) { this.children.push(...children); }
    replaceChildren() { this.children = []; }
    addEventListener(type, listener) { this.listeners[type] = listener; }
    setAttribute(name, value) { this.attributes[name] = value; }
  }
  const nodes = Object.fromEntries(['#status', '#content', '#site', '#secure', '#frame', '#state', '#state-icon'].map(id => [id, new Node()]));
  const calls = []; let retry = false;
  const old = { document: globalThis.document, chrome: globalThis.chrome, window: globalThis.window };
  globalThis.document = { documentElement: {}, querySelectorAll: () => [], querySelector: id => nodes[id], createElement: tag => new Node(tag), addEventListener() {} };
  globalThis.window = { close: () => assert.fail('retry must not close popup') };
  globalThis.chrome = { i18n: { getMessage: key => `localized:${key}`, getUILanguage: () => 'en' }, runtime: { sendMessage: async request => {
    calls.push(request);
    if (request.type === 'getState') return retry ? { state: 'ready' } : { state: 'error', reason: 'disconnected' };
    if (request.type === 'getTarget') return { tabId: 1, frameId: 0, origin: 'https://example.com', token: 'fresh' };
    if (request.type === 'fill') return { ok: false, error: 'denied' };
    return { entries: [entry('fresh')], locked: 0 };
  } } };
  try {
    await import('../src/popup.js');
    await until(() => nodes['#content'].children.some(n => n.textContent === 'localized:tryAgain'));
    const button = nodes['#content'].children.find(n => n.textContent === 'localized:tryAgain');
    retry = true; button.listeners.click();
    await until(() => calls.some(c => c.type === 'getMatches'));
    assert.deepEqual(calls.map(c => c.type), ['getState', 'getState', 'getTarget', 'getMatches']);
    assert.equal(calls.at(-1).token, 'fresh');
    await new Promise(resolve => setImmediate(resolve));
    const row = nodes['#content'].querySelectorAll('.kf-row')[0];
    assert.equal(row.dataset.selected, 'true');
    const [login, code, reveal] = row.children;
    assert.equal(login.attributes['aria-label'], 'localized:fillLogin');
    assert.equal(login.children[1].children[0].textContent, 'fresh');
    assert.equal(login.children[1].children[1].textContent, 'user');
    assert.equal(login.children[2].attributes['aria-label'], 'localized:verificationCode');
    assert.equal(code.attributes['aria-label'], 'localized:fillCode');
    assert.equal(code.title, 'localized:fillCode');
    assert.equal(code.className, 'kf-icon-button');
    assert.equal(code.textContent, '');
    assert.equal(code.children[0].className, 'kf-icon glyph-code');
    assert.equal(reveal.attributes['aria-label'], 'localized:reveal');
    assert.equal(reveal.title, 'localized:reveal');
    assert.equal(reveal.textContent, '');
    code.listeners.click();
    assert.equal(nodes['#status'].textContent, 'localized:confirm');
    assert.equal(nodes['#state-icon'].className, 'kf-waiting');
    await until(() => nodes['#status'].textContent === 'localized:denied');
    assert.deepEqual(calls.at(-1), { type: 'fill', tabId: 1, frameId: 0, token: 'fresh', entry: 'fresh', db: 'a', totp: true });
    assert.equal(nodes['#content'].querySelectorAll('.kf-row').length, 0);
  } finally { Object.assign(globalThis, old); }
});

test('fill with a lost worker pin reselects but never retries the credential action', async () => {
  const calls = [];
  const model = new PopupState(async request => {
    calls.push(request);
    if (request.type === 'fill') return { ok: false, error: 'target-required' };
    if (request.type === 'getState') return { state: 'ready' };
    if (request.type === 'getTarget') return { tabId: 2, frameId: 0, token: 'new' };
    return { entries: [entry('fresh')], locked: 0 };
  });
  model.target = { tabId: 1, frameId: 0, token: 'old' }; model.reply({ entries: [entry('old')] });
  assert.equal(await model.fill(), false);
  assert.deepEqual(calls.map(c => c.type), ['fill', 'getState', 'getTarget', 'getMatches']);
  assert.equal(model.target.token, 'new'); assert.equal(model.entries[0].entry, 'fresh');
});
