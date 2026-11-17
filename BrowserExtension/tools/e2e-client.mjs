#!/usr/bin/env node
// Plays the browser against a real native host: the extension's own Connection over a
// chrome.runtime.connectNative backed by child_process. Reads one JSON command per line on
// stdin and writes one JSON object per line on stdout. KeeForgeMacUITests starts it through
// e2e-client-launcher.sh, outside the runner's sandbox.
// Exit codes: 0 after "quit" or stdin end, 2 bad arguments or host not executable, 3 no WebCrypto X25519.
import { spawn } from 'node:child_process';
import { accessSync, constants } from 'node:fs';
import { createInterface } from 'node:readline';
import { userInfo } from 'node:os';
import { Connection } from '../src/connection.js';
import { KeyStore } from '../src/keystore.js';

const args = process.argv.slice(2);
const hostPath = args[args.indexOf('--host') + 1];
if (!args.includes('--host') || !hostPath) { process.stderr.write('usage: e2e-client.mjs --host <path>\n'); process.exit(2); }
try { accessSync(hostPath, constants.X_OK); } catch { process.stderr.write(`host not executable: ${hostPath}\n`); process.exit(2); }
try { await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']); } catch { process.exit(3); }

const emit = object => process.stdout.write(JSON.stringify(object) + '\n');
// Only what a browser passes: a sandboxed parent's container variables would make the host's
// sandbox initialization try to join that parent's container.
const account = userInfo();
const hostEnvironment = {
  PATH: '/usr/bin:/bin:/usr/sbin:/sbin', HOME: account.homedir, USER: account.username, LOGNAME: account.username,
  SHELL: account.shell ?? '/bin/zsh', LANG: process.env.LANG ?? 'en_US.UTF-8'
};
emit({ event: 'client-ready', hostEnvironment: Object.keys(hostEnvironment), parentSandboxed: 'APP_SANDBOX_CONTAINER_ID' in process.env });
const elapsed = start => Math.round(performance.now() - start);

class Event {
  listeners = new Set();
  addListener(fn) { this.listeners.add(fn); }
  removeListener(fn) { this.listeners.delete(fn); }
  emit(value) { for (const fn of [...this.listeners]) fn(value); }
}

let hostCount = 0;
const runtime = {
  lastError: undefined,
  connectNative(name) {
    const index = ++hostCount;
    const started = performance.now();
    const child = spawn(hostPath, [], { stdio: ['pipe', 'pipe', 'pipe'], env: hostEnvironment });
    let input = Buffer.alloc(0), first = true, disconnected = false, stdinClosedAt = null, exited = false;
    const port = {
      name, onMessage: new Event(), onDisconnect: new Event(),
      postMessage(frame) {
        if (disconnected) throw new Error('disconnected');
        const body = Buffer.from(JSON.stringify(frame));
        const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
        child.stdin.write(Buffer.concat([header, body]));
      },
      disconnect() {
        if (disconnected) return;
        disconnected = true; stdinClosedAt = performance.now(); child.stdin.end();
        // A host that ignores end of file is a finding; report it, then stop it.
        setTimeout(() => { if (!exited) { emit({ event: 'host-still-running', host: index, afterStdinCloseMs: elapsed(stdinClosedAt) }); child.kill(); } }, 3000);
      }
    };
    emit({ event: 'host-spawned', host: index, pid: child.pid });
    child.stdin.on('error', () => {});
    child.stderr.on('data', chunk => emit({ event: 'host-stderr', host: index, text: chunk.toString() }));
    child.stdout.on('data', chunk => {
      input = Buffer.concat([input, chunk]);
      while (input.length >= 4) {
        const length = input.readUInt32LE(0);
        if (input.length < 4 + length) return;
        const frame = JSON.parse(input.subarray(4, 4 + length).toString());
        input = input.subarray(4 + length);
        if (frame.t === 'host') emit({ event: 'host-frame', host: index, frame, ...(first ? { sinceSpawnMs: elapsed(started) } : {}) });
        first = false;
        if (!disconnected) port.onMessage.emit(frame);
      }
    });
    child.on('error', error => emit({ event: 'host-error', host: index, message: error.message }));
    child.on('exit', (code, signal) => {
      exited = true;
      emit({ event: 'host-exit', host: index, code, signal, ...(stdinClosedAt === null ? {} : { afterStdinCloseMs: elapsed(stdinClosedAt) }) });
      if (!disconnected) { disconnected = true; port.onDisconnect.emit(); }
    });
    return port;
  }
};

class MemoryStorage {
  async read() { return this.record && structuredClone(this.record); }
  async write(record) { this.record = structuredClone(record); }
  async clear() { this.record = undefined; }
}

const store = new KeyStore(new MemoryStorage());
const connection = new Connection({ runtime, store, onState: state => emit({ event: 'state', ...state }) });

async function run(command) {
  switch (command.cmd) {
    case 'open': return { ...(await connection.open()) };
    case 'close': connection.close(); return connection.getState();
    case 'state': return connection.getState();
    case 'pair': {
      const { code, result } = await connection.startPairing(command.name);
      emit({ event: 'pair-code', id: command.id, code });
      return { ...(await result) };
    }
    case 'request': return await connection.request(command.type, command.fields ?? {});
    default: throw new Error(`unknown command ${command.cmd}`);
  }
}

const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  let command;
  try { command = JSON.parse(line); } catch { emit({ error: 'bad-command' }); return; }
  if (command.cmd === 'quit') { connection.close(); setTimeout(() => process.exit(0), 500); return; }
  run(command).then(
    result => emit({ id: command.id, done: true, result }),
    error => emit({ id: command.id, done: false, error: error?.code ?? error?.message ?? String(error) })
  );
});
lines.on('close', () => { connection.close(); setTimeout(() => process.exit(0), 500); });
