import { chooseFrame, probeFrame } from './frames.js';
import { injectCredential } from './fill.js';
import { Connection } from './connection.js';
import { ProtocolError, origin, requireThat, integer, object } from './protocol.js';

// Runs in the isolated world; neither result comes from a page-defined property.
export function inspectDocument() {
  return { href: location.href, origin: globalThis.origin };
}
export function deriveOrigin(snapshot) {
  requireThat(object(snapshot) && typeof snapshot.href === 'string', 'bad-origin');
  let url;
  try { url = new URL(snapshot.href); } catch { throw new ProtocolError('bad-origin'); }
  requireThat(['https:', 'http:'].includes(url.protocol), 'bad-origin');
  requireThat(snapshot.origin !== 'null' && snapshot.origin === url.origin, 'bad-origin');
  return origin(snapshot.origin);
}
export async function targetDocument(api, tabId, frameId = 0) {
  requireThat(integer(tabId) && integer(frameId));
  const tab = await api.tabs.get(tabId);
  // Missing URL means activeTab did not grant access to this tab.
  requireThat(typeof tab.url === 'string', 'bad-origin');
  deriveOrigin({ href: tab.url, origin: new URL(tab.url).origin });
  const results = await api.scripting.executeScript({ target: { tabId, frameIds: [frameId] }, func: inspectDocument });
  requireThat(results.length === 1 && results[0].frameId === frameId && !results[0].error, 'bad-origin');
  return { tabId, frameId, documentId: results[0].documentId, origin: deriveOrigin(results[0].result) };
}
export class Background {
  constructor({ api = globalThis.chrome, connection = new Connection(), timers = globalThis, injectCredential = null } = {}) {
    this.api = api; this.connection = connection; this.timers = timers; this.injectCredential = injectCredential;
    this.active = 0; this.popupTarget = null;
  }
  idle() {
    this.timers.clearTimeout(this.idleTimer);
    if (!this.active) this.idleTimer = this.timers.setTimeout(() => { this.popupTarget = null; this.connection.close(); }, 60000);
  }
  async use(operation) {
    ++this.active; this.timers.clearTimeout(this.idleTimer);
    try { return await operation(); } finally { --this.active; this.idle(); }
  }
  async handle(message) {
    requireThat(object(message) && typeof message.type === 'string');
    return this.use(async () => {
      switch (message.type) {
        case 'getState':
          if (!this.connection.getState().reason) await this.connection.open();
          return this.connection.getState();
        case 'launchApp':
          await this.connection.open();
          return ['app-unavailable', 'unpaired', 'ready'].includes(this.connection.state) ? this.connection.hostCommand('launch') : this.connection.getState();
        case 'startPairing': {
          const { code, result } = await this.connection.startPairing(message.name);
          ++this.active;
          result.catch(() => {}).finally(() => { --this.active; this.idle(); });
          return { code };
        }
        case 'getTarget': {
          this.popupTarget = null;
          const tabId = message.tabId ?? (await this.api.tabs.query({ active: true, currentWindow: true }))[0]?.id;
          requireThat(integer(tabId), 'bad-origin');
          const probes = await this.api.scripting.executeScript({ target: { tabId, allFrames: true }, world: 'ISOLATED', func: probeFrame });
          const frameId = chooseFrame(probes);
          requireThat(probes.some(p => p.frameId === frameId && !p.error && p.result?.fillable), 'no-fields');
          this.popupTarget = await targetDocument(this.api, tabId, frameId);
          return this.popupTarget;
        }
        case 'getMatches': {
          const target = await targetDocument(this.api, message.tabId, message.frameId);
          this.checkPopupTarget(target);
          return this.connection.request('matches', { origin: target.origin });
        }
        case 'fill': {
          requireThat(typeof this.injectCredential === 'function', 'fill-not-configured');
          const target = await targetDocument(this.api, message.tabId, message.frameId);
          this.checkPopupTarget(target);
          let credential;
          try {
            credential = await this.connection.request('credential', { entry: message.entry, db: message.db, origin: target.origin, ...(message.totp === true ? { totp: true } : {}) });
            if (!credential.ok) return { ok: false, error: credential.error };
            const current = await targetDocument(this.api, message.tabId, message.frameId);
            requireThat(current.origin === target.origin && current.documentId === target.documentId, 'bad-origin');
            // Adapter must inject into this document and check origin again in the fill function.
            await this.injectCredential(current, credential, message.totp === true);
            return { ok: true };
          } finally {
            if (credential) for (const key of Object.keys(credential)) delete credential[key];
            credential = null;
          }
        }
        case 'reveal': return this.connection.request('reveal', { entry: message.entry, db: message.db });
        case 'unlock': return this.connection.request('unlock', message.db === undefined ? {} : { db: message.db });
        case 'forgetPairing': await this.connection.forgetPairing(); return this.connection.getState();
        default: throw new ProtocolError();
      }
    });
  }
  checkPopupTarget(target) {
    if (!this.popupTarget) return;
    const selected = this.popupTarget;
    requireThat(target.tabId === selected.tabId && target.frameId === selected.frameId && target.origin === selected.origin && target.documentId === selected.documentId, 'bad-origin');
  }
  listen() {
    this.api.runtime.onMessage.addListener((message, sender, respond) => {
      const root = this.api.runtime.getURL('');
      if (sender.id !== this.api.runtime.id || !sender.url?.startsWith(root)) return false;
      this.handle(message).then(respond, error => respond({ ok: false, error: error instanceof ProtocolError ? error.code : error.message === 'no-fields' ? 'no-fields' : 'unavailable' }));
      // Chrome 133 and Firefox share the callback response contract; promises are used for API calls.
      return true;
    });
  }
}
if (globalThis.chrome?.runtime?.onMessage) new Background({ injectCredential: (target, credential, codeOnly) => injectCredential(globalThis.chrome, target, credential, codeOnly) }).listen();
