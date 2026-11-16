import test from 'node:test';
import assert from 'node:assert/strict';
import { Connection } from '../src/connection.js';
import { KeyStore } from '../src/keystore.js';
import { keyPair, publicBytes } from '../src/crypto.js';
import { envelope } from '../src/protocol.js';
import { MockApp, ENTRY, DB } from './mock-app.js';
import { FakeRuntime, MemoryStorage, FakeTimers, until } from './fakes.js';
function setup(options) {
  const app = new MockApp(options); const runtime = new FakeRuntime(app); const store = new KeyStore(new MemoryStorage());
  const timers = new FakeTimers(); const connection = new Connection({ runtime, store, timers });
  return { app, runtime, store, timers, connection };
}
async function paired(options) {
  const s = setup(options);
  const pairing = await s.connection.startPairing();
  await pairing.result;
  assert.equal(pairing.code, s.app.code);
  return s;
}
test('pairing, equal codes, reconnect, concurrent encrypted round trips and no retained replies', async () => {
  const { connection: c, app, runtime, store } = await paired();
  assert.equal(c.state, 'ready'); assert.equal(runtime.ports.length, 1);
  const record = await store.load(); assert.equal(record.client.privateKey.extractable, false);
  assert.equal(record.client.publicKey.extractable, false);
  await assert.rejects(crypto.subtle.exportKey('raw', record.client.publicKey));
  assert.equal(record.app.length, 32);
  await assert.rejects(crypto.subtle.exportKey('pkcs8', record.client.privateKey));
  const statuses = await Promise.all(Array.from({ length: 8 }, () => c.request('status')));
  assert.equal(statuses.length, 8); assert.equal(statuses[0].app, 'mock');
  await c.request('matches', { origin: 'https://example.com' });
  const code = await c.request('credential', { entry: ENTRY, db: DB, origin: 'https://example.com', totp: true });
  assert.deepEqual(code, { id: code.id, ok: true, totp: '123456' });
  const credential = await c.request('credential', { entry: ENTRY, db: DB, origin: 'https://example.com' });
  assert.equal(credential.password, 'mock-password'); assert.equal('totp' in credential, false);
  assert.equal(c.pending.size, 0); assert.equal(c.record, null); assert.equal(c.ephemeral, null);
  c.close(); await c.open(); assert.equal(c.state, 'ready');
  assert.equal((await c.request('status')).ok, true);
  app.clients.clear(); c.close(); await c.open(); assert.deepEqual(c.getState(), { state: 'unpaired', reason: 'unpaired' });
  await c.forgetPairing(); assert.equal((await store.load()).app, null); c.close();
});
test('declined, busy, pending cancellation and pairing timeout', async () => {
  for (const decision of ['decline', 'busy', 'pending']) {
    const { connection: c, store, timers } = setup({ decision });
    if (decision === 'busy') await assert.rejects(c.startPairing(), /pairing-busy/);
    else {
      const pairing = await c.startPairing();
      if (decision === 'pending') { assert.equal(c.state, 'pairing'); timers.fire(120000); }
      await assert.rejects(pairing.result, decision === 'decline' ? /pairing-declined/ : /timeout/);
    }
    assert.equal((await store.load()).app, null); c.close();
  }
  const { connection: c } = setup({ decision: 'pending' });
  const p = await c.startPairing(); c.close(); await assert.rejects(p.result, /disconnected/);
});
test('host missing sync and async, unavailable, launch, connect and socket closure', async () => {
  for (const missing of [true, 'throw']) {
    const c = new Connection({ runtime: new FakeRuntime(undefined, { missing }), timers: new FakeTimers() });
    await c.open(); assert.equal(c.state, 'host-missing');
  }
  const s = setup(); s.runtime.available = false;
  await s.connection.open(); assert.deepEqual(s.connection.getState(), { state: 'app-unavailable', reason: 'not-running' });
  const port = s.connection.port;
  s.runtime.available = true; await s.connection.hostCommand('launch');
  assert.equal(s.connection.state, 'unpaired'); assert.equal(s.connection.port, port);
  port.emit(envelope('host', { event: 'unavailable', reason: 'closed' }));
  await until(() => s.connection.state === 'app-unavailable');
  await s.connection.hostCommand('connect'); assert.equal(s.connection.state, 'unpaired');
  assert.deepEqual(s.runtime.commands, ['launch', 'connect']); s.connection.close();
});
test('handshake timeout and wrong app static key fail closed', async () => {
  const s = await paired();
  await s.store.pair(await publicBytes(await keyPair()));
  s.connection.close(); await s.connection.open();
  await assert.rejects(s.connection.request('status'), /bad-handshake/);
  assert.equal(s.connection.state, 'error'); assert.equal(s.connection.cipher, null);
  const t = setup(); t.runtime.connectNative = () => ({ onMessage: { addListener() {}, removeListener() {} }, onDisconnect: { addListener() {}, removeListener() {} }, disconnect() {} });
  const opening = t.connection.open(); t.timers.fire(10000); await opening;
  assert.equal(t.connection.reason, 'timeout');
});
test('wrong client static key cannot authenticate', async () => {
  const s = await paired();
  const record = await s.store.load(); await s.store.storage.write({ ...record, client: { ...record.client, privateKey: (await keyPair()).privateKey } });
  s.connection.close(); await s.connection.open(); assert.equal(s.connection.state, 'ready');
  await assert.rejects(s.connection.request('status'), /bad-handshake/);
  assert.equal(s.connection.cipher, null);
});
for (const n of [0, 2]) test(`counter ${n === 0 ? 'replay' : 'skip'} tears down`, async () => {
  const s = await paired(); await s.connection.request('status');
  s.app.frameTransform = f => ({ ...f, n });
  await assert.rejects(s.connection.request('status'), /bad-handshake/);
  assert.equal(s.connection.port, null); assert.equal(s.connection.pending.size, 0);
});
test('tag failure, malformed reply, unsolicited id, second hello and malformed envelopes tear down', async () => {
  for (const mode of ['tag', 'reply', 'id', 'hello', 'version', 'unknown', 'oversize']) {
    const s = await paired();
    if (mode === 'reply') s.app.replyTransform = r => ({ ...r, unlocked: 'one' });
    else if (mode === 'id') s.app.replyTransform = r => ({ ...r, id: 999 });
    else s.app.frameTransform = f => mode === 'tag' ? { ...f, c: btoa('x'.repeat(32)) } : mode === 'hello' ? envelope('hello', { eph: btoa('x'.repeat(32)), app: '1' }) : mode === 'version' ? { ...f, v: 2 } : mode === 'oversize' ? { ...f, extra: 'x'.repeat(1048576) } : envelope('unknown');
    await assert.rejects(s.connection.request('status'));
    assert.equal(s.connection.state, 'error'); assert.equal(s.connection.port, null);
  }
});
test('timeouts are 120 seconds for credential, 10 seconds otherwise and close all pending', async () => {
  for (const type of ['status', 'matches', 'reveal', 'unlock', 'credential']) {
    const s = await paired({ dropReplies: true });
    const result = s.connection.request(type, type === 'matches' ? { origin: 'https://example.com' } : type === 'status' || type === 'unlock' ? {} : { entry: ENTRY, db: DB, origin: 'https://example.com' });
    const ms = type === 'credential' ? 120000 : 10000;
    await until(() => [...s.timers.tasks.values()].some(t => t.ms === ms));
    s.timers.fire(type === 'credential' ? 10000 : 120000); assert.equal(s.connection.state, 'ready');
    s.timers.fire(ms); await assert.rejects(result, /timeout/); assert.equal(s.connection.pending.size, 0);
  }
});
test('forget pairing creates a fresh non-extractable profile identity', async () => {
  const store = new KeyStore(new MemoryStorage());
  const [a, b] = await Promise.all([store.load(), store.load()]);
  assert.deepEqual(await publicBytes(a.client), await publicBytes(b.client));
  await store.forget(); const c = await store.load();
  assert.notDeepEqual(await publicBytes(a.client), await publicBytes(c.client));
});
test('remote disable and connected/unavailable control events discard pending session work', async () => {
  for (const mode of ['disabled', 'closed', 'duplicate-connected', 'disconnect']) {
    const s = await paired({ dropReplies: true });
    const pending = s.connection.request('status'); await until(() => s.connection.pending.size === 1);
    const port = s.connection.port;
    if (mode === 'disabled') port.emit(envelope('error', { code: 'disabled' }));
    if (mode === 'closed') port.emit(envelope('host', { event: 'unavailable', reason: 'closed' }));
    if (mode === 'duplicate-connected') port.emit(envelope('host', { event: 'connected' }));
    if (mode === 'disconnect') port.onDisconnect.emit();
    await assert.rejects(pending);
    assert.equal(s.connection.cipher, null); assert.equal(s.connection.pending.size, 0);
    assert.equal(s.connection.state, mode === 'closed' ? 'app-unavailable' : 'error');
    if (mode === 'closed') { assert.equal(s.connection.port, port); await s.connection.hostCommand('connect'); assert.equal(s.connection.state, 'ready'); }
    s.connection.close();
  }
});
test('pairing while paired uses a new connection; concurrent starts cannot replace a waiting pairing', async () => {
  const s = await paired(); const old = s.connection.port;
  s.app.decision = 'pending';
  const first = s.connection.startPairing();
  const second = s.connection.startPairing();
  await assert.rejects(second, /pairing-busy/);
  const p = await first; assert.notEqual(s.connection.port, old); assert.equal(old.disconnected, true);
  await assert.rejects(s.connection.startPairing(), /pairing-busy/);
  s.connection.close(); await assert.rejects(p.result);
});
test('mock UI scenarios return real protocol matches including mixed exactness and databases', async () => {
  for (const scenario of ['locked', 'empty', 'mixed']) {
    const s = await paired({ scenario });
    const reply = await s.connection.request('matches', { origin: 'https://example.com' });
    assert.equal(reply.locked, scenario === 'locked' ? 1 : 0);
    assert.equal(reply.entries.length, scenario === 'mixed' ? 3 : 0);
    if (scenario === 'mixed') {
      assert.deepEqual(reply.entries.map(entry => entry.exact), [false, true, true]);
      assert.equal(new Set(reply.entries.map(entry => entry.db)).size, 2);
      for (const entry of reply.entries) assert.equal((await s.connection.request('credential', { entry: entry.entry, db: entry.db, origin: 'https://example.com' })).ok, true);
    }
    s.connection.close();
  }
});
test('outbound frame cap counts JSON bytes only, excluding the native header', () => {
  const s = setup(); const frames = []; s.connection.port = { postMessage: frame => frames.push(frame) };
  const frame = { padding: '' }, overhead = new TextEncoder().encode(JSON.stringify(frame)).length;
  frame.padding = 'x'.repeat(65536 - overhead); s.connection.send(frame); assert.equal(frames.length, 1);
  assert.throws(() => s.connection.send({ padding: frame.padding + 'x' }));
});
test('Open KeeForge fronts an already-running paired app through launch on a fresh session', async () => {
  const s = await paired(); const previous = s.connection.port;
  assert.equal((await s.connection.hostCommand('launch')).state, 'ready');
  assert.equal(previous.disconnected, true); assert.deepEqual(s.runtime.commands, ['launch']);
  assert.equal((await s.connection.request('status')).ok, true); s.connection.close();
});

test('popup reconnect after a real disconnect or timeout establishes a fresh working session', async () => {
  const { Background } = await import('../src/background.js');
  for (const mode of ['disconnected', 'timeout']) {
    const s = await paired(); const background = new Background({ connection: s.connection, timers: s.timers });
    if (mode === 'disconnected') s.connection.port.onDisconnect.emit();
    else {
      s.app.dropReplies = true;
      const pending = s.connection.request('status'); await until(() => s.connection.pending.size === 1);
      s.timers.fire(10000); await assert.rejects(pending, /timeout/); s.app.dropReplies = false;
    }
    assert.equal(s.connection.reason, mode);
    assert.equal((await background.handle({ type: 'getState', reconnect: true })).state, 'ready');
    assert.equal((await s.connection.request('status')).ok, true); assert.equal(s.runtime.ports.length, 2); s.connection.close();
  }
});
