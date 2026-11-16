import test from 'node:test';
import assert from 'node:assert/strict';
import { Background, deriveOrigin, targetDocument } from '../src/background.js';
import { FakeTimers, Event } from './fakes.js';
const accepted = ['https://example.com', 'https://example.com:8443', 'https://xn--bcher-kva.example', 'http://localhost', 'http://localhost:8080', 'http://127.0.0.1', 'http://[::1]:8080'];
const refused = ['http://example.com', 'http://localhost.example.com', 'http://127.0.0.2', 'file:///tmp/example', 'about:blank', 'data:text/html,test', 'chrome://extensions', 'edge://settings', 'moz-extension://a/page', 'chrome-extension://a/page', 'javascript:alert(1)', 'blob:https://example.com/id', 'ftp://example.com'];
for (const href of [...accepted, ...refused]) test(`origin ${href}`, () => {
  const snapshot = { href, origin: new URL(href).origin };
  if (accepted.includes(href)) assert.equal(deriveOrigin(snapshot), href);
  else assert.throws(() => deriveOrigin(snapshot));
});
test('opaque, mismatched, missing and malformed document origins are refused', () => {
  for (const s of [null, {}, { href: 'not-url', origin: 'https://example.com' }, { href: 'https://example.com', origin: 'null' }, { href: 'https://example.com', origin: 'https://evil.example' }]) assert.throws(() => deriveOrigin(s));
});
function setup() {
  const timers = new FakeTimers(); let snapshot = { href: 'https://example.com/path', origin: 'https://example.com' };
  const api = { tabs: { async get() { return { url: 'https://example.com/path' }; } }, scripting: { async executeScript({ target }) { return [{ frameId: target.frameIds[0], documentId: 'doc', result: snapshot }]; } } };
  const calls = []; const credential = { id: 2, ok: true, username: 'demo', password: 'secret', totp: '123456' };
  const connection = { state: 'ready', async open() { calls.push('open'); }, getState() { return { state: this.state }; }, close() { calls.push('close'); }, async request(type, fields) { calls.push({ type, fields }); return type === 'credential' ? credential : { ok: true }; }, async forgetPairing() { calls.push('forget'); } };
  const fills = [];
  const b = new Background({ api, timers, connection, injectCredential: async (target, value) => { fills.push({ target, value }); assert.equal(value.password, 'secret'); } });
  return { b, api, calls, credential, fills, timers, connection, navigate(s) { snapshot = s; } };
}
test('browser origin overrides UI, frames use browser data, credential is consumed and cleared', async () => {
  const s = setup(); assert.deepEqual(s.calls, []);
  await s.b.handle({ type: 'getMatches', tabId: 1, frameId: 3, origin: 'https://evil.example' });
  assert.deepEqual(s.calls[0], { type: 'matches', fields: { origin: 'https://example.com' } });
  const result = await s.b.handle({ type: 'fill', tabId: 1, frameId: 3, entry: 'e', db: 'd', origin: 'https://evil.example' });
  assert.deepEqual(result, { ok: true }); assert.deepEqual(s.credential, {});
  assert.equal(s.fills[0].target.frameId, 3); assert.equal(s.fills[0].target.origin, 'https://example.com');
  assert.deepEqual(s.fills[0].value, {});
  assert.equal(Object.values(s.b).includes(s.credential), false);
  assert.equal(JSON.stringify(s.b).includes('secret'), false);
  s.timers.fire(60000); assert.equal(s.calls.at(-1), 'close');
});
test('fill failure and navigation clear credentials; no configured seam releases nothing', async () => {
  for (const mode of ['throw', 'navigate', 'document', 'no-seam']) {
    const s = setup();
    if (mode === 'throw') s.b.injectCredential = async () => { throw new Error('injection-failed'); };
    if (mode === 'no-seam') s.b.injectCredential = null;
    const original = s.connection.request;
    s.connection.request = async (...args) => {
      const value = await original(...args);
      if (mode === 'navigate') s.navigate({ href: 'https://elsewhere.example', origin: 'https://elsewhere.example' });
      if (mode === 'document') s.api.scripting.executeScript = async () => [{ frameId: 0, documentId: 'other', result: { href: 'https://example.com', origin: 'https://example.com' } }];
      return value;
    };
    await assert.rejects(s.b.handle({ type: 'fill', tabId: 1, entry: 'e', db: 'd' }));
    if (mode !== 'no-seam') assert.deepEqual(s.credential, {});
    else assert.equal(s.calls.length, 0);
    assert.equal(s.fills.length, 0);
  }
});
test('target refuses inaccessible tab/frame and injection failure', async () => {
  for (const mode of ['tab', 'frame', 'missing', 'opaque', 'throw']) {
    const s = setup();
    if (mode === 'tab') s.api.tabs.get = async () => ({});
    else if (mode === 'throw') s.api.scripting.executeScript = async () => { throw new Error('denied'); };
    else s.api.scripting.executeScript = async () => mode === 'missing' ? [] : [{ frameId: mode === 'frame' ? 99 : 0, result: { href: 'https://example.com', origin: 'null' } }];
    await assert.rejects(targetDocument(s.api, 1));
    assert.equal(s.calls.length, 0);
  }
  await assert.rejects(targetDocument(setup().api, -1));
});
test('internal API authentication, response errors, lazy open and idle close', async () => {
  const s = setup(); const event = new Event();
  s.api.runtime = { id: 'self', getURL: () => 'chrome-extension://self/', onMessage: event };
  s.b.listen(); const listener = [...event.listeners][0];
  for (const sender of [{ id: 'other', url: 'chrome-extension://self/a' }, { id: 'self', url: 'https://example.com' }, { id: 'self' }]) assert.equal(listener({ type: 'getState' }, sender, () => assert.fail()), false);
  const response = await new Promise(resolve => assert.equal(listener({ type: 'getState' }, { id: 'self', url: 'chrome-extension://self/popup.html' }, resolve), true));
  assert.equal(response.state, 'ready'); assert.deepEqual(s.calls, ['open']);
  await s.b.handle({ type: 'forgetPairing' }); assert.equal(s.calls.at(-1), 'forget');
  await s.b.handle({ type: 'reveal', entry: 'e', db: 'd' });
  await s.b.handle({ type: 'unlock' });
  await assert.rejects(s.b.handle({ type: 'unknown' }));
  s.timers.fire(60000); assert.equal(s.calls.at(-1), 'close');
});
test('pairing holds the port beyond idle timeout and poll preserves decline reason', async () => {
  const s = setup(); let complete;
  const result = new Promise(resolve => { complete = resolve; });
  s.connection.startPairing = async () => { s.connection.state = 'pairing'; return { code: '001234', result }; };
  s.connection.getState = () => ({ state: s.connection.state, reason: s.connection.reason ?? null });
  assert.deepEqual(await s.b.handle({ type: 'startPairing' }), { code: '001234' });
  assert.equal(s.b.active, 1); s.timers.fire(60000); assert.equal(s.calls.includes('close'), false);
  s.connection.state = 'unpaired'; s.connection.reason = 'pairing-declined'; complete();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await s.b.handle({ type: 'getState' }), { state: 'unpaired', reason: 'pairing-declined' });
  assert.equal(s.calls.includes('open'), false);
  s.timers.fire(60000); assert.equal(s.calls.at(-1), 'close');
});
test('Firefox target without documentId uses inspected frame origin; credential errors never inject', async () => {
  const s = setup();
  s.api.scripting.executeScript = async ({ target }) => [{ frameId: target.frameIds[0], result: { href: 'https://example.com', origin: 'https://example.com' } }];
  await s.b.handle({ type: 'fill', tabId: 1, frameId: 2, entry: 'e', db: 'd' });
  assert.equal(s.fills[0].target.documentId, undefined); assert.equal(s.fills[0].target.frameId, 2);
  const denied = setup(); denied.connection.request = async () => ({ id: 1, ok: false, error: 'denied' });
  assert.deepEqual(await denied.b.handle({ type: 'fill', tabId: 1 }), { ok: false, error: 'denied' });
  assert.equal(denied.fills.length, 0);
});
test('popup target is background-derived, focused frame is pinned through matching and filling', async () => {
  const s = setup();
  const inspect = s.api.scripting.executeScript;
  s.api.scripting.executeScript = async options => options.target.allFrames ? [{ frameId: 0, result: { focused: false, fillable: true } }, { frameId: 3, result: { focused: true, fillable: true } }] : inspect(options);
  s.api.tabs.query = async () => [{ id: 1 }];
  assert.deepEqual(await s.b.handle({ type: 'getTarget' }), { tabId: 1, frameId: 3, documentId: 'doc', origin: 'https://example.com' });
  await s.b.handle({ type: 'getMatches', tabId: 1, frameId: 3 });
  s.navigate({ href: 'https://elsewhere.example', origin: 'https://elsewhere.example' });
  await assert.rejects(s.b.handle({ type: 'fill', tabId: 1, frameId: 3, entry: 'e', db: 'd' }), /bad-origin/);
  assert.equal(s.calls.some(call => call.type === 'credential'), false);
});
test('popup refuses a target without any visible editable field', async () => {
  const s = setup(); s.api.scripting.executeScript = async () => [{ frameId: 0, result: { focused: false, fillable: false } }];
  await assert.rejects(s.b.handle({ type: 'getTarget', tabId: 1 }), /no-fields/);
});
