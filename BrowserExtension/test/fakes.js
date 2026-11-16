import { envelope } from '../src/protocol.js';
import { MockApp } from './mock-app.js';
export class MemoryStorage {
  async read() { return this.record && structuredClone(this.record); }
  async write(record) { this.record = structuredClone(record); }
  async clear() { this.record = undefined; }
}
export class Event {
  listeners = new Set();
  addListener(fn) { this.listeners.add(fn); }
  removeListener(fn) { this.listeners.delete(fn); }
  emit(value) { for (const fn of this.listeners) fn(value); }
}
export class FakeRuntime {
  constructor(app = new MockApp(), { missing = false, available = true } = {}) {
    this.app = app; this.missing = missing; this.available = available; this.ports = []; this.commands = [];
  }
  connectNative(name) {
    if (this.missing === 'throw') throw new Error('missing');
    const runtime = this;
    const port = {
      name, onMessage: new Event(), onDisconnect: new Event(), disconnected: false,
      emit(frame) { if (!this.disconnected) this.onMessage.emit(frame); },
      disconnect() { this.disconnected = true; },
      postMessage(frame) {
        if (this.disconnected) throw new Error('disconnected');
        if (frame.t === 'host') {
          runtime.commands.push(frame.cmd);
          queueMicrotask(() => connect()); return;
        }
        queue = queue.then(() => session.receive(frame)).catch(error => port.emit(envelope('error', { code: error.code ?? 'bad-handshake' })));
      }
    };
    let session, queue = Promise.resolve();
    const connect = () => {
      if (runtime.missing) { port.onDisconnect.emit(); return; }
      if (!runtime.available) port.emit(envelope('host', { event: 'unavailable', reason: 'not-running' }));
      else { session = runtime.app.connect(frame => port.emit(frame)); port.session = session; port.emit(envelope('host', { event: 'connected' })); }
    };
    this.ports.push(port); queueMicrotask(connect); return port;
  }
}
export class FakeTimers {
  next = 0; tasks = new Map();
  setTimeout(fn, ms) { const id = ++this.next; this.tasks.set(id, { fn, ms }); return id; }
  clearTimeout(id) { this.tasks.delete(id); }
  fire(ms) { for (const [id, task] of [...this.tasks]) if (task.ms === ms) { this.tasks.delete(id); task.fn(); } }
}
export async function until(predicate) {
  for (let i = 0; i < 500; i++) { if (predicate()) return; await new Promise(resolve => setTimeout(resolve, 2)); }
  throw new Error('condition-timeout');
}
