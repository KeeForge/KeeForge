import test from 'node:test';
import assert from 'node:assert/strict';
import { Background, CAPTURE_MS } from '../src/background.js';
import { FakeTimers, Event } from './fakes.js';
// A content script's submitted login: held only in memory, sent to the app only after the page shows the outcome.
function setup({ paired = true, features = ['generate', 'save'] } = {}) {
  const timers = new FakeTimers(), requests = [];
  const sender = { id: 'self', tab: { id: 7 }, frameId: 3, documentId: 'doc', url: 'https://example.com/login', origin: 'https://example.com' };
  let documentId = 'doc';
  const api = {
    runtime: { id: 'self', getURL: path => 'chrome-extension://self/' + path, onMessage: new Event() },
    tabs: { get: async () => ({ url: 'https://example.com/login' }), onRemoved: new Event() },
    scripting: { executeScript: async ({ target }) => [{ frameId: target.frameIds[0], documentId, result: { origin: 'https://example.com', href: 'https://example.com/login', token: 'pin' } }] }
  };
  const connection = {
    state: 'ready', features, opened: 0, pairedChecks: 0,
    async open() { this.opened++; }, async isPaired() { this.pairedChecks++; return paired; }, getState() { return { state: this.state }; }, close() {},
    async request(type, fields) { requests.push({ type, fields: { ...fields } }); return { ok: true }; }
  };
  const b = new Background({ api, connection, timers });
  const submit = (fields = {}, from = sender) => b.serialTab(7, () => b.loginSubmitted({ username: 'demo', password: 'secret', generated: false, ...fields }, from));
  const outcome = async (succeeded, from = sender) => { const reply = await b.serialTab(7, () => b.loginOutcome({ succeeded }, from)); await b.saving; return reply; };
  return { b, api, connection, requests, timers, sender, submit, outcome, replaceDocument() { documentId = 'other'; } };
}
test('a typed login reaches the app only after the sign-in went through, with the browser-derived origin, and is then forgotten', async () => {
  const s = setup();
  assert.deepEqual(await s.submit(), { ok: true });
  assert.deepEqual(s.requests, []); assert.equal(s.connection.opened, 0, 'nothing contacts the app at submit');
  assert.equal(JSON.stringify([...s.b.captures.values()].map(({ timer, ...rest }) => rest)).includes('secret'), true);
  assert.deepEqual(await s.outcome(true), { ok: true });
  assert.deepEqual(s.requests, [{ type: 'save', fields: { origin: 'https://example.com', username: 'demo', password: 'secret' } }]);
  assert.equal(s.b.captures.size, 0);
  assert.equal(JSON.stringify(s.b).includes('secret'), false);
  await assert.rejects(s.outcome(true), { code: 'target-required' }, 'one outcome per submission');
  assert.equal(s.requests.length, 1);
});
test('a failed or abandoned typed login is dropped; a generated one is still offered, since losing it would lock the user out', async () => {
  let s = setup();
  await s.submit(); await s.outcome(false);
  assert.deepEqual(s.requests, []); assert.equal(s.b.captures.size, 0);
  await s.submit({ generated: true }); await s.outcome(false);
  assert.deepEqual(s.requests.map(r => r.type), ['save']);
  s = setup();
  await s.submit(); s.timers.fire(CAPTURE_MS);
  assert.equal(s.b.captures.size, 0, 'a submission without an outcome expires');
  await assert.rejects(s.outcome(true), { code: 'target-required' });
  assert.deepEqual(s.requests, []);
  s = setup();
  await s.submit({ username: 'first' }); await s.submit({ username: 'second' }); await s.outcome(true);
  assert.deepEqual(s.requests.map(r => r.fields.username), ['second'], 'a new submission replaces the one before');
});
test('an unpaired profile never starts the native host, and an app without save gets no request', async () => {
  let s = setup({ paired: false });
  assert.deepEqual(await s.submit(), { ok: true });
  assert.equal(s.b.captures.size, 0); assert.equal(s.connection.opened, 0);
  await assert.rejects(s.outcome(true), { code: 'target-required' });
  s = setup({ features: [] });
  await s.submit(); await s.outcome(true);
  assert.deepEqual(s.requests, []);
});
test('only the submitting document reports its outcome, and a submission must come from the frame it names', async () => {
  let s = setup();
  await s.submit();
  for (const patch of [{ documentId: 'other' }, { frameId: 4 }, { id: 'other' }, { tab: { id: 8 } }]) await assert.rejects(s.outcome(true, { ...s.sender, ...patch }), undefined, JSON.stringify(patch));
  assert.deepEqual(s.requests, []);
  s = setup(); s.replaceDocument();
  await assert.rejects(s.submit(), { code: 'bad-origin' }, 'the inspected document is another one');
  for (const patch of [{ origin: 'https://evil.example' }, { url: 'http://example.com/', origin: 'http://example.com' }, { id: 'other' }, { tab: undefined }]) {
    s = setup(); await assert.rejects(s.submit({}, { ...s.sender, ...patch }), undefined, JSON.stringify(patch)); assert.equal(s.b.captures.size, 0);
  }
});
test('malformed submissions are refused before anything is kept', async () => {
  for (const fields of [{ password: '' }, { password: 'x'.repeat(1025) }, { username: 'u'.repeat(1025) }, { username: 7 }, { generated: 'yes' }, { password: undefined }]) {
    const s = setup(); await assert.rejects(s.submit(fields), { code: 'bad-request' }, JSON.stringify(fields));
    assert.equal(s.b.captures.size, 0); assert.equal(s.connection.pairedChecks, 0);
  }
});
test('content-script messages reach the flow through the listener, and closing the tab drops a waiting login', async () => {
  const s = setup(); s.b.listen();
  const listener = [...s.api.runtime.onMessage.listeners][0];
  const send = message => new Promise(resolve => assert.equal(listener(message, s.sender, resolve), true));
  assert.deepEqual(await send({ type: 'loginSubmitted', username: 'demo', password: 'secret', generated: false }), { ok: true });
  assert.equal(s.b.captures.size, 1);
  s.api.tabs.onRemoved.emit(7);
  assert.equal(s.b.captures.size, 0);
  assert.deepEqual(await send({ type: 'loginOutcome', succeeded: true }), { ok: false, error: 'target-required' });
  assert.deepEqual(s.requests, []);
});
