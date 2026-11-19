#!/usr/bin/env node
import { MockApp } from '../test/mock-app.js';
import { envelope, validateEnvelope, object } from '../src/protocol.js';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const app = new MockApp({ decision: process.argv.includes('--decline') ? 'decline' : process.argv.includes('--busy') ? 'busy' : process.argv.includes('--pending') ? 'pending' : 'allow', scenario: process.argv.includes('--locked') ? 'locked' : process.argv.includes('--empty') ? 'empty' : process.argv.includes('--mixed') ? 'mixed' : 'default', holdCredential: process.argv.includes('--hold-credential') });
let available = !process.argv.includes('--unavailable');
// Development checks: <dir>/state.json switches availability and scenario live; <dir>/log.jsonl records what arrived.
const control = process.argv.includes('--control') ? process.argv[process.argv.indexOf('--control') + 1] : null;
function log(entry) { if (control) appendFileSync(join(control, 'log.jsonl'), JSON.stringify({ pid: process.pid, ...entry }) + '\n'); }
function applyControl() {
  if (!control) return;
  let state;
  try { state = JSON.parse(readFileSync(join(control, 'state.json'), 'utf8')); } catch { return; }
  if (typeof state.available === 'boolean') available = state.available;
  if (state.scenario && state.scenario !== app.scenario) app.setScenario(state.scenario);
  app.credentialDelay = Number.isInteger(state.credentialDelay) ? state.credentialDelay : 0;
}
app.onRequest = request => { applyControl(); log({ request: request.type, origin: request.origin, totp: request.totp }); };
// Each native connection is a new process; keep the app identity and pairings across them like the real app.
if (control) app.staticReady = app.staticReady.then(async () => {
  const file = join(control, 'identity.json'), bytes = value => new Uint8Array(Buffer.from(value, 'base64'));
  const load = () => { try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; } };
  let saved = load();
  if (!saved) {
    const key = await crypto.subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']);
    saved = { key: Buffer.from(await crypto.subtle.exportKey('pkcs8', key.privateKey)).toString('base64'), pub: Buffer.from(await crypto.subtle.exportKey('raw', key.publicKey)).toString('base64'), clients: {} };
    writeFileSync(file, JSON.stringify(saved));
  }
  app.static = { privateKey: await crypto.subtle.importKey('pkcs8', bytes(saved.key), 'X25519', false, ['deriveBits']), publicKey: await crypto.subtle.importKey('raw', bytes(saved.pub), 'X25519', true, []) };
  app.clients = new class extends Map {
    get(id) { const c = load()?.clients[id]; return c ? bytes(c) : undefined; }
    set(id, c) { const current = load(); current.clients[id] = Buffer.from(c).toString('base64'); writeFileSync(file, JSON.stringify(current)); return this; }
  }();
});
log({ started: true });
applyControl();
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
  log({ frame: object(frame) ? frame.t : typeof frame, cmd: frame?.cmd });
  applyControl();
  if (object(frame) && frame.t === 'host') {
    validateEnvelope(frame, 'client');
    if (frame.cmd === 'launch' && !control) available = true;
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
