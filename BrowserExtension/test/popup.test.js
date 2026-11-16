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
  assert.deepEqual(calls, [{ type: 'fill', tabId: 1, frameId: 3, entry: '1', db: 'a' }]);
  finish({ ok: true }); assert.equal(await filling, true);
  assert.deepEqual(model.entries, []); assert.equal(model.target, null); assert.equal(model.state, 'done');
});
test('code fills request only ids plus code flag and failure leaves no rows', async () => {
  const model = new PopupState(async request => { assert.deepEqual(request, { type: 'fill', tabId: 7, frameId: 0, entry: '1', db: 'a', totp: true }); return { ok: false, error: 'no-match' }; });
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
