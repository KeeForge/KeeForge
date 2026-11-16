#!/usr/bin/env node
import { MockApp } from '../test/mock-app.js';
import { envelope, validateEnvelope, object } from '../src/protocol.js';

const app = new MockApp({ decision: process.argv.includes('--decline') ? 'decline' : process.argv.includes('--busy') ? 'busy' : 'allow' });
let available = !process.argv.includes('--unavailable');
let session;
let input = Buffer.alloc(0), queue = Promise.resolve();
function send(frame) {
  const body = Buffer.from(JSON.stringify(frame));
  if (body.length > 1048576) { process.exitCode = 1; process.stdin.destroy(); return; }
  const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  process.stdout.write(Buffer.concat([header, body]));
}
function connect() {
  if (!available) { send(envelope('host', { event: 'unavailable', reason: 'not-running' })); return; }
  session = app.connect(send); send(envelope('host', { event: 'connected' }));
}
async function receive(frame) {
  if (object(frame) && frame.t === 'host') {
    validateEnvelope(frame, 'client');
    if (frame.cmd === 'launch') available = true;
    connect();
  } else {
    if (!session) throw new Error('unavailable');
    await session.receive(frame);
  }
}
function stop() { process.exitCode = 1; process.stdin.destroy(); }
process.stdin.on('data', chunk => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 4) {
    const length = input.readUInt32LE(0);
    if (length === 0 || length > 65536) { stop(); return; }
    if (input.length < 4 + length) return;
    let frame;
    try { frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(input.subarray(4, 4 + length))); }
    catch { stop(); return; }
    input = input.subarray(4 + length);
    queue = queue.then(() => receive(frame)).catch(error => {
      send(envelope('error', { code: error.code && ['bad-request', 'unsupported-version', 'bad-handshake'].includes(error.code) ? error.code : 'bad-request' }));
      stop();
    });
  }
});
process.stdin.on('end', () => { if (input.length) process.exitCode = 1; });
process.stdin.on('error', stop);
process.stdout.on('error', stop);
connect();
