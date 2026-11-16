import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { Connection } from '../src/connection.js';
import { KeyStore } from '../src/keystore.js';
import { MemoryStorage, Event } from './fakes.js';
import { ENTRY, DB } from './mock-app.js';
function host(args = []) {
  const child = spawn(process.execPath, [new URL('../tools/mock-host.mjs', import.meta.url).pathname, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = Buffer.alloc(0); const frames = [], errors = [];
  child.stderr.on('data', data => errors.push(data));
  const port = { onMessage: new Event(), onDisconnect: new Event(), disconnect() { child.stdin.end(); }, postMessage(frame) {
    const body = Buffer.from(JSON.stringify(frame)), header = Buffer.alloc(4); header.writeUInt32LE(body.length);
    // Deliberately fragment frames across pipe writes.
    child.stdin.write(header.subarray(0, 2)); child.stdin.write(Buffer.concat([header.subarray(2), body]));
  } };
  child.stdout.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
      const size = buffer.readUInt32LE(0); const frame = JSON.parse(buffer.subarray(4, size + 4));
      buffer = buffer.subarray(4 + size); frames.push(frame); port.onMessage.emit(frame);
    }
  });
  child.on('exit', () => port.onDisconnect.emit());
  return { child, port, frames, errors };
}
test('runnable stdio mock host pairs and serves encrypted replies without diagnostics', async t => {
  const h = host(); t.after(() => h.child.kill());
  const c = new Connection({ runtime: { connectNative: () => h.port }, store: new KeyStore(new MemoryStorage()) });
  const pairing = await c.startPairing(); assert.match(pairing.code, /^\d{6}$/); await pairing.result;
  await c.request('matches', { origin: 'https://example.com' });
  const credential = await c.request('credential', { entry: ENTRY, db: DB, origin: 'https://example.com' });
  assert.equal(credential.password, 'mock-password');
  const exited = once(h.child, 'exit'); c.close();
  assert.equal((await exited)[0], 0); assert.equal(h.errors.length, 0);
  assert.equal(h.frames.some(frame => 'password' in frame), false);
});
test('stdio mock launch from unavailable and malformed/oversized/truncated input', async t => {
  const h = host(['--unavailable']); t.after(() => h.child.kill());
  const c = new Connection({ runtime: { connectNative: () => h.port }, store: new KeyStore(new MemoryStorage()) });
  await c.open(); assert.equal(c.state, 'app-unavailable');
  await c.hostCommand('launch'); assert.equal(c.state, 'unpaired');
  const exited = once(h.child, 'exit'); c.close(); assert.equal((await exited)[0], 0);
  for (const data of [Buffer.from([1, 0, 1, 0]), Buffer.from([1, 0, 0, 0, 123]), Buffer.from([4, 0, 0, 0, 123])]) {
    const bad = host(); const ended = once(bad.child, 'exit'); bad.child.stdin.end(data);
    assert.equal((await ended)[0], 1);
  }
});
