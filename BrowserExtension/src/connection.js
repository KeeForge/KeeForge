import { HOST, ProtocolError, envelope, validateEnvelope, request, validateReply, requireThat, object, integer } from './protocol.js';
import { Cipher, keyPair, publicBytes, random, toBase64, fromBase64, commitment, pairingCode, clientId, clientKeys } from './crypto.js';
import { KeyStore } from './keystore.js';

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  // Pairing may finish before its UI begins polling the result.
  promise.catch(() => {});
  return { promise, resolve, reject };
}
export class Connection {
  constructor({ runtime = globalThis.chrome?.runtime, store = new KeyStore(), timers = globalThis, onState = () => {} } = {}) {
    this.runtime = runtime; this.store = store; this.timers = timers; this.onState = onState;
    this.state = 'unpaired'; this.reason = null; this.port = null; this.phase = 'closed';
    this.pending = new Map(); this.nextId = 0; this.generation = 0;
    this.rx = Promise.resolve(); this.tx = Promise.resolve();
  }
  getState() { return { state: this.state, reason: this.reason }; }
  setState(state, reason = null) { this.state = state; this.reason = reason; this.onState(this.getState()); }
  check(generation) { requireThat(this.port && this.generation === generation, 'unavailable'); }
  send(frame) {
    requireThat(this.port, 'unavailable');
    requireThat(new TextEncoder().encode(JSON.stringify(frame)).length <= 65536);
    this.port.postMessage(frame);
  }
  deadline(ms) {
    this.timers.clearTimeout(this.stageTimer);
    this.stageTimer = this.timers.setTimeout(() => this.fail(new ProtocolError('timeout')), ms);
  }
  settleOpen() { this.opening?.resolve(this.getState()); this.opening = null; }
  async open({ pairing = false } = {}) {
    if (this.port) return this.opening ? this.opening.promise : this.getState();
    this.opening = deferred();
    const opened = this.opening.promise;
    this.suppressHello = pairing;
    this.phase = 'host';
    ++this.generation;
    try {
      this.port = this.runtime.connectNative(HOST);
      const port = this.port;
      this.messageListener = frame => {
        if (this.port !== port) return;
        const generation = this.generation;
        this.rx = this.rx.then(async () => {
          if (generation !== this.generation) return;
          requireThat(new TextEncoder().encode(JSON.stringify(frame)).length <= 1048576);
          await this.receive(validateEnvelope(frame), generation);
        }).catch(error => { if (generation === this.generation) this.fail(error); });
      };
      this.disconnectListener = () => {
        // Reading lastError suppresses Chrome's unchecked runtime error; never retain its text.
        void this.runtime.lastError;
        if (this.port !== port) return;
        const missing = this.phase === 'host';
        this.close(missing ? 'host-missing' : 'error', missing ? 'host-missing' : 'disconnected');
      };
      this.port.onMessage.addListener(this.messageListener);
      this.port.onDisconnect.addListener(this.disconnectListener);
      this.deadline(10000);
    } catch { this.close('host-missing', 'host-missing'); }
    return opened;
  }
  close(state = 'unpaired', reason = null, keepPort = false) {
    ++this.generation;
    this.timers.clearTimeout(this.stageTimer);
    const error = new ProtocolError(reason ?? 'disconnected');
    for (const pending of this.pending.values()) { this.timers.clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    this.pairStart?.reject(error); this.pairResult?.reject(error);
    this.pairStart = null; this.pairResult = null;
    const port = this.port;
    if (!keepPort) this.port = null;
    if (port && !keepPort) {
      port.onMessage.removeListener(this.messageListener);
      port.onDisconnect.removeListener(this.disconnectListener);
      port.disconnect();
    }
    this.cipher = null; this.record = null; this.ephemeral = null;
    this.pairing = null; this.phase = keepPort ? 'unavailable' : 'closed'; this.nextId = 0;
    this.tx = Promise.resolve(); this.rx = Promise.resolve();
    this.setState(state, reason); this.settleOpen();
  }
  fail(error) {
    const code = error instanceof ProtocolError ? error.code : 'bad-handshake';
    try { this.send(envelope('error', { code: ['unsupported-version', 'bad-request', 'bad-handshake'].includes(code) ? code : 'bad-request' })); } catch { /* Port may already be closed. */ }
    this.close('error', code);
  }
  async hostCommand(cmd) {
    await this.open();
    if (!this.port) return this.getState();
    requireThat(this.phase === 'unavailable' || this.phase === 'unpaired');
    this.phase = 'host-retry'; this.opening = deferred();
    const result = this.opening.promise;
    this.deadline(cmd === 'launch' ? 11000 : 10000);
    this.send(envelope('host', { cmd }));
    return result;
  }
  async hello(generation) {
    this.record = await this.store.load(); this.check(generation);
    if (!this.record.app || this.suppressHello) {
      this.phase = 'unpaired'; this.setState('unpaired'); this.settleOpen(); return;
    }
    this.ephemeral = await keyPair(); this.check(generation);
    const eph = toBase64(await publicBytes(this.ephemeral));
    const client = await clientId(await publicBytes(this.record.client)); this.check(generation);
    this.phase = 'hello'; this.deadline(10000);
    this.send(envelope('hello', { client, eph }));
  }
  async startPairing(name = 'Browser') {
    requireThat(typeof name === 'string' && [...name].length <= 64);
    requireThat(this.state !== 'pairing', 'pairing-busy');
    // A connection that has already sent hello cannot carry another session.
    if (this.port && this.phase !== 'unpaired') this.close();
    await this.open({ pairing: true });
    requireThat(this.phase === 'unpaired', this.reason ?? 'unavailable');
    const generation = this.generation;
    this.phase = 'pair-preparing'; this.setState('pairing');
    this.pairStart = deferred(); this.pairResult = deferred();
    const started = this.pairStart.promise;
    try {
      const ec = await keyPair(); const c = await publicBytes(this.record.client);
      const eph = await publicBytes(ec); const nonce = random();
      const commit = toBase64(await commitment(c, eph, nonce)); this.check(generation);
      this.pairing = { ec, c, eph, nonce }; this.phase = 'pair-key'; this.deadline(10000);
      this.send(envelope('pair-commit', { commit, name }));
    } catch (error) { if (generation === this.generation) this.fail(error); }
    return started;
  }
  async receive(frame, generation) {
    if (frame.t === 'host') {
      if (frame.event === 'unavailable') {
        const opening = this.opening; this.opening = null;
        this.close('app-unavailable', frame.reason, true);
        // A closed socket discards session keys while the relay remains available for launch.
        opening?.resolve(this.getState());
        return;
      }
      requireThat(['host', 'host-retry'].includes(this.phase));
      this.timers.clearTimeout(this.stageTimer);
      await this.hello(generation); return;
    }
    if (frame.t === 'error') {
      const state = frame.code === 'unpaired' || frame.code === 'pairing-declined' || frame.code === 'pairing-busy' ? 'unpaired' : 'error';
      this.close(state, frame.code); return;
    }
    switch (this.phase) {
      case 'pair-key': {
        requireThat(frame.t === 'pair-key');
        const s = fromBase64(frame.pub, 32), es = fromBase64(frame.eph, 32);
        const p = this.pairing;
        const code = await pairingCode(p.c, s, p.eph, es); this.check(generation);
        p.app = s; this.phase = 'pair-result'; this.deadline(120000);
        this.send(envelope('pair-reveal', { pub: toBase64(p.c), eph: toBase64(p.eph), nonce: toBase64(p.nonce) }));
        this.pairStart.resolve({ code, result: this.pairResult.promise }); this.pairStart = null;
        return;
      }
      case 'pair-result': {
        requireThat(frame.t === 'pair-result');
        await this.store.pair(this.pairing.app); this.check(generation);
        this.pairing = null; this.suppressHello = false;
        await this.hello(generation); return;
      }
      case 'hello': {
        requireThat(frame.t === 'hello');
        const keys = await clientKeys(this.record.client, this.ephemeral, this.record.app, fromBase64(frame.eph, 32)); this.check(generation);
        this.cipher = new Cipher(keys.c2s, keys.s2c);
        this.record = null; this.ephemeral = null; this.phase = 'ready';
        this.timers.clearTimeout(this.stageTimer); this.setState('ready'); this.settleOpen();
        this.pairResult?.resolve(this.getState()); this.pairResult = null; return;
      }
      case 'ready': {
        requireThat(frame.t === 'msg');
        const reply = await this.cipher.open(frame); this.check(generation);
        requireThat(object(reply) && integer(reply.id));
        const pending = this.pending.get(reply.id); requireThat(pending);
        const validated = validateReply(reply, pending.request);
        this.pending.delete(reply.id); this.timers.clearTimeout(pending.timer);
        pending.resolve(validated); return;
      }
      default: throw new ProtocolError();
    }
  }
  async request(type, fields = {}) {
    await this.open();
    requireThat(this.state === 'ready' && this.phase === 'ready', this.reason ?? 'unpaired');
    const generation = this.generation;
    const message = request(this.nextId++, type, fields);
    const reply = deferred();
    const timer = this.timers.setTimeout(() => this.close('error', 'timeout'), type === 'credential' ? 120000 : 10000);
    this.pending.set(message.id, { ...reply, timer, request: message });
    this.tx = this.tx.then(async () => {
      this.check(generation);
      const frame = await this.cipher.seal(message); this.check(generation); this.send(frame);
    }).catch(error => { if (generation === this.generation) this.fail(error); });
    return reply.promise;
  }
  async forgetPairing() { this.close(); await this.store.forget(); }
}
