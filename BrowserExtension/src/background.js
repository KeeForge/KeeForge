import { chooseFrame, probeFrame } from './frames.js';
import { injectCredential, injectGenerated } from './fill.js';
import { Connection } from './connection.js';
import { ProtocolError, SAVED_FIELD_LIMIT, origin, requireThat, integer, object } from './protocol.js';

// Runs in the isolated world; neither result comes from a page-defined property.
export function inspectDocument() {
  return { href: location.href, origin: globalThis.origin, token: globalThis.__keeforgeDocumentPin };
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
  // The browser exposes this URL only with activeTab or the declared host grant.
  requireThat(typeof tab.url === 'string', 'bad-origin');
  deriveOrigin({ href: tab.url, origin: new URL(tab.url).origin });
  const results = await api.scripting.executeScript({ target: { tabId, frameIds: [frameId] }, world: 'ISOLATED', func: inspectDocument });
  requireThat(results.length === 1 && results[0].frameId === frameId && !results[0].error, 'bad-origin');
  return { tabId, frameId, documentId: results[0].documentId, origin: deriveOrigin(results[0].result), token: results[0].result.token };
}
export function prepareInlineDocument(forced) { return globalThis.__keeforgePrepareInline?.(forced); }
export const CONTEXT_KINDS = { 'fill-username': 'username', 'fill-password': 'password', 'fill-code': 'code' };
const CONTEXT_TITLES = { 'fill-username': 'contextFillUsername', 'fill-password': 'contextFillPassword', 'fill-code': 'fillCode' };
const GRANT_MS = 10000;
// A submitted login waits at most this long for the page to show whether the sign-in went through.
export const CAPTURE_MS = 15000;
export class Background {
  constructor({ api = globalThis.chrome, connection = new Connection(), timers = globalThis, injectCredential = null, injectGenerated = null } = {}) {
    this.api = api; this.connection = connection; this.timers = timers; this.injectCredential = injectCredential; this.injectGenerated = injectGenerated;
    this.active = 0; this.popupTarget = null; this.menus = new Map(); this.menuOpenings = new Map(); this.grants = new Map();
    this.captures = new Map(); this.captureQueues = new Map();
  }
  async createContextMenus() {
    const menus = this.api.contextMenus;
    if (!menus) return;
    await menus.removeAll();
    const patterns = this.api.runtime.getManifest().content_scripts[0].matches;
    const create = properties => new Promise(done => menus.create(properties, () => { void this.api.runtime.lastError; done(); }));
    await create({ id: 'keeforge', title: this.api.i18n.getMessage('extensionName'), contexts: ['editable'], documentUrlPatterns: patterns });
    for (const [id, key] of Object.entries(CONTEXT_TITLES)) await create({ id, parentId: 'keeforge', title: this.api.i18n.getMessage(key), contexts: ['editable'], documentUrlPatterns: patterns });
  }
  // Only the browser's own menu click reaches here, so the page cannot ask for a forced fill.
  async contextClicked(info, tab) {
    const kind = CONTEXT_KINDS[info?.menuItemId], frameId = info?.frameId ?? 0;
    if (!kind || !integer(tab?.id) || !integer(frameId)) return;
    let frameOrigin = null;
    try { frameOrigin = new URL(info.frameUrl || info.pageUrl).origin; } catch {}
    this.grants.set(tab.id, { frameId, frameOrigin, kind, expires: Date.now() + GRANT_MS });
    await this.api.tabs.sendMessage(tab.id, { type: 'contextFill', kind }, { frameId }).catch(() => {});
  }
  takeGrant(sender, kind, senderOrigin) {
    const grant = this.grants.get(sender.tab.id);
    this.grants.delete(sender.tab.id);
    requireThat(grant && grant.kind === kind && grant.frameId === sender.frameId && grant.expires >= Date.now() && (grant.frameOrigin === null || grant.frameOrigin === senderOrigin), 'target-required');
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
          if (message.reconnect === true || !this.connection.getState().reason) {
            if (message.reconnect === true && this.connection.phase === 'unavailable') await this.connection.hostCommand('connect');
            else await this.connection.open();
          }
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
          // Selection replaces the document pin an open inline menu depends on; close it rather than leave it broken.
          this.menuOpenings.delete(tabId);
          if (this.menus.has(tabId)) await this.closeMenu(this.menus.get(tabId));
          // Browser pages and tabs without an activeTab grant reject injection outright.
          const probes = await this.api.scripting.executeScript({ target: { tabId, allFrames: true }, world: 'ISOLATED', func: probeFrame }).catch(() => { throw new ProtocolError('bad-origin'); });
          const frameId = chooseFrame(probes);
          requireThat(probes.some(p => p.frameId === frameId && !p.error && p.result?.fillable), 'no-fields');
          const selected = probes.find(p => p.frameId === frameId);
          const target = await targetDocument(this.api, tabId, frameId);
          requireThat(typeof selected.result.token === 'string' && target.token === selected.result.token && target.documentId === selected.documentId, 'bad-origin');
          this.popupTarget = target;
          return this.popupTarget;
        }
        case 'getMatches': {
          requireThat(this.popupTarget && message.token === this.popupTarget.token, 'target-required');
          const target = await targetDocument(this.api, message.tabId, message.frameId);
          this.checkPopupTarget(target, message);
          return this.connection.request('matches', { origin: target.origin });
        }
        case 'fill': {
          requireThat(typeof this.injectCredential === 'function', 'fill-not-configured');
          requireThat(this.popupTarget && message.token === this.popupTarget.token, 'target-required');
          const target = await targetDocument(this.api, message.tabId, message.frameId);
          this.checkPopupTarget(target, message);
          return this.fillTarget(target, message, async () => {
            const current = await targetDocument(this.api, message.tabId, message.frameId);
            this.checkPopupTarget(current, message); return current;
          });
        }
        case 'reveal': return this.connection.request('reveal', { entry: message.entry, db: message.db });
        case 'unlock': return this.connection.request('unlock', message.db === undefined ? {} : { db: message.db });
        case 'forgetPairing': await this.connection.forgetPairing(); return this.connection.getState();
        default: throw new ProtocolError();
      }
    });
  }
  async fillTarget(target, message, recheck) {
    requireThat(typeof this.injectCredential === 'function', 'fill-not-configured');
    let credential;
    try {
      credential = await this.connection.request('credential', { entry: message.entry, db: message.db, origin: target.origin, ...(message.totp === true ? { totp: true } : {}) });
      if (!credential.ok) return { ok: false, error: credential.error };
      requireThat(message.totp === true
        ? typeof credential.totp === 'string' && credential.username === undefined && credential.password === undefined
        : typeof credential.username === 'string' && typeof credential.password === 'string' && credential.totp === undefined);
      const current = await recheck();
      await this.injectCredential(current, credential, message.totp === true);
      return { ok: true };
    } finally {
      if (credential) for (const key of Object.keys(credential)) delete credential[key];
      credential = null;
    }
  }
  async closeMenu(session, refocus = false) {
    if (this.menus.get(session.tabId) !== session) return;
    this.menus.delete(session.tabId);
    await this.api.tabs.sendMessage(session.tabId, { type: 'closeInlineMenu', token: session.menuToken, refocus }, { frameId: session.frameId, ...(session.documentId ? { documentId: session.documentId } : {}) }).catch(() => {});
  }
  async openMenu(sender, forced) {
    requireThat(sender.id === this.api.runtime.id && integer(sender.tab?.id) && integer(sender.frameId), 'bad-origin');
    const senderOrigin = deriveOrigin({ href: sender.url, origin: sender.origin ?? new URL(sender.url).origin });
    requireThat(forced === undefined || Object.values(CONTEXT_KINDS).includes(forced), 'bad-origin');
    if (forced) this.takeGrant(sender, forced, senderOrigin);
    const tabId = sender.tab.id, frameId = sender.frameId;
    const opening = {}; this.menuOpenings.set(tabId, opening);
    const previous = this.menus.get(tabId);
    if (previous) await this.closeMenu(previous);
    const prepared = await this.api.scripting.executeScript({ target: sender.documentId ? { tabId, documentIds: [sender.documentId] } : { tabId, frameIds: [frameId] }, world: 'ISOLATED', func: prepareInlineDocument, args: forced ? [forced] : [] });
    requireThat(prepared.length === 1 && prepared[0].frameId === frameId && prepared[0].documentId === sender.documentId && (forced ? prepared[0].result?.kind === forced : ['login', 'code', 'username', 'new'].includes(prepared[0].result?.kind)), 'bad-origin');
    const target = await targetDocument(this.api, tabId, frameId);
    requireThat(target.origin === senderOrigin && target.documentId === sender.documentId && typeof target.token === 'string' && target.token === prepared[0].result.token, 'bad-origin');
    requireThat(this.menuOpenings.get(tabId) === opening, 'target-required');
    this.menuOpenings.delete(tabId);
    // A right-clicked field detection cannot use still gets a menu, but one that only explains why it cannot fill.
    const session = { ...target, inline: true, kind: prepared[0].result.kind, ...(forced ? { forced: true, blocked: prepared[0].result.usable !== true } : {}), menuToken: crypto.randomUUID() };
    this.menus.set(tabId, session);
    return { token: session.menuToken };
  }
  menuSession(message, sender) {
    const session = this.menus.get(sender.tab?.id);
    const inlineURLs = [this.api.runtime.getURL('inline.html'), this.api.runtime.getURL('') + 'inline.html'];
    requireThat(sender.id === this.api.runtime.id && integer(sender.frameId) && sender.frameId > 0 && inlineURLs.includes(sender.url?.split(/[?#]/)[0]) && session && message.token === session.menuToken, 'target-required');
    // The first menu document to call owns the session; any other document with the token means the frame was reloaded or replaced.
    session.menuFrame ??= { frameId: sender.frameId, documentId: sender.documentId };
    if (session.menuFrame.frameId !== sender.frameId || session.menuFrame.documentId !== sender.documentId) { void this.closeMenu(session); throw new ProtocolError('target-required'); }
    return session;
  }
  async checkMenu(session) {
    requireThat(this.menus.get(session.tabId) === session, 'target-required');
    const target = await targetDocument(this.api, session.tabId, session.frameId);
    requireThat(this.menus.get(session.tabId) === session && target.documentId === session.documentId && target.origin === session.origin && target.token === session.token, 'bad-origin');
    return { ...target, inline: true, kind: session.kind, ...(session.forced ? { forced: true } : {}) };
  }
  async handleMenu(message, sender) {
    const session = this.menuSession(message, sender);
    // Closing needs no target check; the content script is told through the browser, never through the page.
    if (message.action === 'close') { await this.closeMenu(session, message.refocus === true); return { ok: true }; }
    return this.use(async () => {
      await this.checkMenu(session);
      if (session.blocked) { requireThat(message.action === 'state', 'field-unusable'); return { ok: false, error: 'field-unusable', origin: session.origin }; }
      let reply;
      switch (message.action) {
        case 'state': {
          const state = await this.handle({ type: 'getState', reconnect: true });
          if (state.state !== 'ready') { reply = { ...state, origin: session.origin }; break; }
          reply = await this.connection.request('matches', { origin: session.origin });
          if (session.kind === 'code' && reply.entries) reply = { ...reply, entries: reply.entries.filter(entry => entry.hasTotp) };
          reply = { ...reply, origin: session.origin, kind: session.kind, ...(session.kind === 'new' ? { generate: this.connection.features.includes('generate') } : {}) };
          break;
        }
        case 'generate': {
          // An app without `generate` would close the connection on the unknown request.
          requireThat(session.kind === 'new' && typeof this.injectGenerated === 'function' && this.connection.features.includes('generate'), 'unavailable');
          let generated;
          try {
            generated = await this.connection.request('generate', { origin: session.origin });
            if (!generated.ok) { reply = { ok: false, error: generated.error }; break; }
            await this.injectGenerated(await this.checkMenu(session), generated.password);
          } finally {
            if (generated) delete generated.password;
            generated = null;
          }
          await this.closeMenu(session, true);
          return { ok: true };
        }
        case 'pair': await this.api.tabs.create({ url: this.api.runtime.getURL('pair.html') }); reply = { ok: true }; break;
        case 'launchApp': reply = await this.handle({ type: 'launchApp' }); break;
        case 'unlock': reply = await this.handle({ type: 'unlock' }); break;
        case 'reveal': reply = await this.handle({ type: 'reveal', entry: message.entry, db: message.db }); break;
        case 'fill':
          reply = await this.fillTarget(session, { ...message, totp: session.kind === 'code' || message.totp === true }, () => this.checkMenu(session));
          if (reply.ok) { await this.closeMenu(session, true); return reply; }
          break;
        default: throw new ProtocolError();
      }
      await this.checkMenu(session);
      return reply;
    });
  }
  // One tab's submitted login and its outcome are handled in order, so a fast navigation's outcome cannot pass its login.
  serialTab(tabId, operation) {
    const result = (this.captureQueues.get(tabId) ?? Promise.resolve()).then(operation);
    const settled = result.catch(() => {});
    this.captureQueues.set(tabId, settled);
    settled.then(() => { if (this.captureQueues.get(tabId) === settled) this.captureQueues.delete(tabId); });
    return result;
  }
  dropCapture(tabId, capture = this.captures.get(tabId)) {
    if (!capture || this.captures.get(tabId) !== capture) return;
    this.captures.delete(tabId); this.timers.clearTimeout(capture.timer);
    capture.username = null; capture.password = null;
  }
  // A trusted submit of a form with a password: the login is kept in memory only until the page shows the outcome.
  async loginSubmitted(message, sender) {
    requireThat(sender.id === this.api.runtime.id && integer(sender.tab?.id) && integer(sender.frameId), 'bad-origin');
    const { username, password, generated } = message;
    requireThat(typeof username === 'string' && [...username].length <= SAVED_FIELD_LIMIT && typeof password === 'string' && password.length > 0 && [...password].length <= SAVED_FIELD_LIMIT && typeof generated === 'boolean');
    const tabId = sender.tab.id;
    const senderOrigin = deriveOrigin({ href: sender.url, origin: sender.origin ?? new URL(sender.url).origin });
    this.dropCapture(tabId);
    // An unpaired profile never starts the native host for this.
    if (!(await this.connection.isPaired())) return { ok: true };
    const target = await targetDocument(this.api, tabId, sender.frameId);
    requireThat(target.origin === senderOrigin && target.documentId === sender.documentId, 'bad-origin');
    const capture = { frameId: sender.frameId, documentId: sender.documentId, origin: senderOrigin, username, password, generated };
    capture.timer = this.timers.setTimeout(() => this.dropCapture(tabId, capture), CAPTURE_MS);
    this.captures.set(tabId, capture);
    return { ok: true };
  }
  // A typed password is offered only after a sign-in that went through; a generated one either way, since losing it locks the user out.
  async loginOutcome(message, sender) {
    const tabId = sender.tab?.id, capture = this.captures.get(tabId);
    requireThat(sender.id === this.api.runtime.id && capture && capture.frameId === sender.frameId && capture.documentId === sender.documentId && typeof message.succeeded === 'boolean', 'target-required');
    const fields = { origin: capture.origin, username: capture.username, password: capture.password };
    const offer = message.succeeded || capture.generated;
    this.dropCapture(tabId, capture);
    if (offer) this.saving = this.use(() => this.save(fields)).catch(() => {});
    else { fields.username = null; fields.password = null; }
    return { ok: true };
  }
  // The app's alert can take minutes; nothing waits on it, and the page learns nothing of it.
  async save(fields) {
    try {
      await this.connection.open();
      if (this.connection.state !== 'ready' || !this.connection.features.includes('save')) return;
      await this.connection.request('save', fields);
    } finally { fields.username = null; fields.password = null; }
  }
  checkPopupTarget(target, message) {
    requireThat(this.popupTarget && message.token === this.popupTarget.token, 'target-required');
    const selected = this.popupTarget;
    requireThat(target.tabId === selected.tabId && target.frameId === selected.frameId && target.origin === selected.origin && target.documentId === selected.documentId && typeof target.token === 'string' && target.token === selected.token, 'bad-origin');
  }
  listen() {
    this.api.tabs.onRemoved?.addListener(tabId => { this.menus.delete(tabId); this.menuOpenings.delete(tabId); this.grants.delete(tabId); this.dropCapture(tabId); });
    this.api.runtime.onInstalled?.addListener(() => void this.createContextMenus().catch(() => {}));
    this.api.runtime.onStartup?.addListener(() => void this.createContextMenus().catch(() => {}));
    this.api.contextMenus?.onClicked.addListener((info, tab) => void this.contextClicked(info, tab));
    this.api.runtime.onMessage.addListener((message, sender, respond) => {
      const root = this.api.runtime.getURL('');
      let operation;
      if (message?.type === 'openInlineMenu') operation = () => this.openMenu(sender, message.forced);
      else if (message?.type === 'loginSubmitted') operation = () => this.serialTab(sender.tab?.id, () => this.use(() => this.loginSubmitted(message, sender)));
      else if (message?.type === 'loginOutcome') operation = () => this.serialTab(sender.tab?.id, () => this.use(() => this.loginOutcome(message, sender)));
      else if (message?.type === 'inlineMenu') operation = () => this.handleMenu(message, sender);
      else if (message?.type === 'closeInlineMenu') operation = async () => {
        const session = this.menus.get(sender.tab?.id);
        requireThat(sender.id === this.api.runtime.id && session && session.frameId === sender.frameId && session.documentId === sender.documentId && message.token === session.menuToken, 'target-required');
        await this.closeMenu(session); return { ok: true };
      };
      else {
        if (sender.id !== this.api.runtime.id || !['popup.html', 'pair.html'].some(page => sender.url === root + page)) return false;
        operation = () => this.handle(message);
      }
      operation().then(respond, error => respond({ ok: false, error: error instanceof ProtocolError ? error.code : error.message === 'no-fields' ? 'no-fields' : 'unavailable' }));
      // Chrome 133 and Firefox share the callback response contract; promises are used for API calls.
      return true;
    });
  }
}
if (globalThis.chrome?.runtime?.onMessage) new Background({
  injectCredential: (target, credential, codeOnly) => injectCredential(globalThis.chrome, target, credential, codeOnly),
  injectGenerated: (target, password) => injectGenerated(globalThis.chrome, target, password)
}).listen();
