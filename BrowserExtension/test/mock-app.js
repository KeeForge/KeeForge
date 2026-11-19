import { envelope, validateEnvelope, validateRequest, requireThat } from '../src/protocol.js';
import { Cipher, keyPair, publicBytes, random, fromBase64, toBase64, commitment, pairingCode, clientId, concat, dh, schedule } from '../src/crypto.js';

export const ENTRY = '11111111-1111-4111-8111-111111111111';
export const DB = '22222222-2222-4222-8222-222222222222';
export class MockApp {
  constructor({ decision = 'allow', dropReplies = false, scenario = 'default', holdCredential = false } = {}) {
    this.decision = decision; this.dropReplies = dropReplies; this.holdCredential = holdCredential; this.scenario = scenario;
    const first = { entry: ENTRY, db: DB, dbName: 'Development', title: 'Example', username: 'demo', hasTotp: true, exact: true };
    this.demoEntry = first;
    this.mixed = [
      { ...first, entry: '33333333-3333-4333-8333-333333333333', title: 'Related host', exact: false },
      { ...first, entry: '44444444-4444-4444-8444-444444444444', db: '55555555-5555-4555-8555-555555555555', dbName: 'Work', title: 'Work login', hasTotp: false }, first
    ];
    this.setScenario(scenario); this.clients = new Map();
    this.staticReady = keyPair().then(key => { this.static = key; });
  }
  // Like the app: 'locked' has no unlocked database, so matches and credentials answer `locked`; 'partly-locked' has one
  // unlocked database with rows and one locked database counted in `locked`.
  setScenario(scenario) {
    this.scenario = scenario;
    this.entries = ['locked', 'empty'].includes(scenario) ? [] : scenario === 'mixed' ? this.mixed : [this.demoEntry];
    this.lockedCount = ['locked', 'partly-locked'].includes(scenario) ? 1 : 0;
  }
  connect(send) { return new MockSession(this, send); }
}
export class MockSession {
  constructor(app, send) { this.app = app; this.send = send; this.phase = 'initial'; this.offered = new Set(); }
  async receive(frame) {
    await this.app.staticReady;
    validateEnvelope(frame, 'client');
    const s = await publicBytes(this.app.static);
    if (frame.t === 'error') { this.phase = 'closed'; return; }
    if (frame.t === 'pair-commit') {
      requireThat(this.phase === 'initial');
      if (this.app.decision === 'busy') { this.send(envelope('error', { code: 'pairing-busy' })); return; }
      this.commit = frame.commit; this.ec = await keyPair(); this.phase = 'reveal';
      this.send(envelope('pair-key', { pub: toBase64(s), eph: toBase64(await publicBytes(this.ec)) })); return;
    }
    if (frame.t === 'pair-reveal') {
      requireThat(this.phase === 'reveal');
      const c = fromBase64(frame.pub, 32), ec = fromBase64(frame.eph, 32);
      requireThat(toBase64(await commitment(c, ec, fromBase64(frame.nonce, 32))) === this.commit, 'bad-handshake');
      this.app.code = await pairingCode(c, s, ec, await publicBytes(this.ec));
      if (this.app.decision === 'pending') return;
      if (this.app.decision === 'decline') { this.send(envelope('error', { code: 'pairing-declined' })); return; }
      this.app.clients.set(await clientId(c), c); this.phase = 'initial';
      this.send(envelope('pair-result', { ok: true })); return;
    }
    if (frame.t === 'hello') {
      requireThat(this.phase === 'initial');
      const c = this.app.clients.get(frame.client);
      if (!c) { this.send(envelope('error', { code: 'unpaired' })); return; }
      const ec = fromBase64(frame.eph, 32); const es = await keyPair(); const esPub = await publicBytes(es);
      const parts = await Promise.all([dh(es.privateKey, ec), dh(es.privateKey, c), dh(this.app.static.privateKey, ec)]);
      const keys = await schedule(concat(...parts), c, s, ec, esPub); parts.forEach(p => p.fill(0));
      this.cipher = new Cipher(keys.s2c, keys.c2s); this.phase = 'ready';
      this.send(envelope('hello', { eph: toBase64(esPub), app: 'mock' })); return;
    }
    requireThat(frame.t === 'msg' && this.phase === 'ready');
    const request = validateRequest(await this.cipher.open(frame));
    this.app.onRequest?.(request);
    if (this.app.dropReplies || (this.app.holdCredential && request.type === 'credential')) return;
    if (request.type === 'credential' && this.app.credentialDelay) await new Promise(resolve => setTimeout(resolve, this.app.credentialDelay));
    let reply = { id: request.id, ok: true };
    switch (request.type) {
      case 'status': Object.assign(reply, { app: 'mock', unlocked: this.app.scenario === 'locked' ? 0 : 1, locked: this.app.lockedCount }); break;
      case 'matches':
        if (this.app.scenario === 'locked') { reply = { id: request.id, ok: false, error: 'locked' }; break; }
        this.offered.add(request.origin);
        Object.assign(reply, { entries: this.app.entries, locked: this.app.lockedCount }); break;
      case 'credential':
        if (this.app.scenario === 'locked') reply = { id: request.id, ok: false, error: 'locked' };
        else if (!this.offered.has(request.origin) || !this.app.entries.some(entry => entry.entry === request.entry && entry.db === request.db)) reply = { id: request.id, ok: false, error: 'not-offered' };
        else if (request.totp) {
          if (this.app.entries.find(entry => entry.entry === request.entry && entry.db === request.db).hasTotp) reply.totp = '123456';
          else reply = { id: request.id, ok: false, error: 'unavailable' };
        } else Object.assign(reply, { username: 'demo', password: 'mock-password' });
        break;
    }
    if (this.app.replyTransform) reply = this.app.replyTransform(reply);
    const response = await this.cipher.seal(reply);
    this.send(this.app.frameTransform ? this.app.frameTransform(response) : response);
  }
}
