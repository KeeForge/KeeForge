export const VERSION = 1;
export const HOST = 'com.keevault.browser';
export const OUTER_ERRORS = Object.freeze(['unsupported-version', 'bad-request', 'unpaired', 'bad-handshake', 'pairing-declined', 'pairing-busy', 'disabled']);
export const INNER_ERRORS = Object.freeze(['bad-request', 'bad-origin', 'locked', 'not-offered', 'no-match', 'denied', 'unavailable', 'rate-limited', 'exists', 'declined', 'save-failed']);
// A `save` request's user name and password are each at most this many characters (UTF-16 code units are not characters, so count code points).
export const SAVED_FIELD_LIMIT = 1024;
export class ProtocolError extends Error {
  constructor(code = 'bad-request') { super(code); this.code = code; }
}
export function requireThat(condition, code = 'bad-request') {
  if (!condition) throw new ProtocolError(code);
}
export const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
export const integer = x => Number.isSafeInteger(x) && x >= 0;
const string = x => typeof x === 'string';
export const uuid = x => string(x) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x);
export function base64(value, length) {
  requireThat(string(value) && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value));
  const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
  requireThat(length === undefined || bytes.length === length);
  // Reject noncanonical padding bits as well as unpadded input.
  let encoded = '';
  for (const byte of bytes) encoded += String.fromCharCode(byte);
  requireThat(btoa(encoded) === value);
  return bytes;
}
export function envelope(t, fields = {}) { return { ...fields, v: VERSION, t }; }
export function validateEnvelope(frame, direction = 'app') {
  requireThat(object(frame));
  requireThat(typeof frame.v === 'number');
  requireThat(frame.v === VERSION, 'unsupported-version');
  requireThat(string(frame.t));
  switch (frame.t) {
    case 'host':
      if (direction === 'client') requireThat(['launch', 'connect'].includes(frame.cmd));
      else {
        requireThat(['connected', 'unavailable'].includes(frame.event));
        if (frame.event === 'unavailable') requireThat(['not-running', 'closed'].includes(frame.reason));
      }
      break;
    case 'error': requireThat(OUTER_ERRORS.includes(frame.code)); break;
    case 'pair-commit':
      base64(frame.commit, 32);
      requireThat(string(frame.name) && [...frame.name].length <= 64); break;
    case 'pair-key': base64(frame.pub, 32); base64(frame.eph, 32); break;
    case 'pair-reveal': base64(frame.pub, 32); base64(frame.eph, 32); base64(frame.nonce, 32); break;
    case 'pair-result': requireThat(frame.ok === true); break;
    case 'hello':
      base64(frame.eph, 32);
      if (direction === 'client') requireThat(string(frame.client) && /^[0-9a-f]{32}$/.test(frame.client));
      else {
        requireThat(string(frame.app));
        // An older app sends no feature list.
        requireThat(frame.features === undefined || (Array.isArray(frame.features) && frame.features.length <= 16 && frame.features.every(string)));
      }
      break;
    case 'msg': requireThat(integer(frame.n)); requireThat(base64(frame.c).length >= 16); break;
    default: throw new ProtocolError();
  }
  return frame;
}
export function origin(value) {
  requireThat(string(value), 'bad-origin');
  let url;
  try { url = new URL(value); } catch { throw new ProtocolError('bad-origin'); }
  requireThat(url.origin !== 'null' && value === url.origin && (
    url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))
  ), 'bad-origin');
  return url.origin;
}
export function validateRequest(request) {
  requireThat(object(request) && integer(request.id));
  switch (request.type) {
    case 'status': break;
    case 'matches': origin(request.origin); break;
    case 'credential':
      origin(request.origin);
      requireThat(request.totp === undefined || request.totp === true);
      requireThat(uuid(request.entry) && uuid(request.db)); break;
    case 'reveal': requireThat(uuid(request.entry) && uuid(request.db)); break;
    case 'unlock': requireThat(request.db === undefined || uuid(request.db)); break;
    case 'generate': origin(request.origin); break;
    case 'save':
      origin(request.origin);
      requireThat(string(request.username) && [...request.username].length <= SAVED_FIELD_LIMIT);
      requireThat(string(request.password) && request.password.length > 0 && [...request.password].length <= SAVED_FIELD_LIMIT);
      break;
    default: throw new ProtocolError();
  }
  return request;
}
export function request(id, type, fields = {}) { return validateRequest({ ...fields, id, type }); }
export function validateReply(reply, request) {
  requireThat(object(reply) && integer(reply.id) && reply.id === request.id && typeof reply.ok === 'boolean');
  if (!reply.ok) { requireThat(INNER_ERRORS.includes(reply.error)); return { id: reply.id, ok: false, error: reply.error }; }
  const result = { id: reply.id, ok: true };
  switch (request.type) {
    case 'status':
      requireThat(string(reply.app) && integer(reply.unlocked) && integer(reply.locked));
      return { ...result, app: reply.app, unlocked: reply.unlocked, locked: reply.locked };
    case 'matches':
      requireThat(Array.isArray(reply.entries) && reply.entries.length <= 50 && integer(reply.locked));
      return { ...result, locked: reply.locked, entries: reply.entries.map(e => {
        requireThat(object(e) && uuid(e.entry) && uuid(e.db) && string(e.dbName) && string(e.title) && string(e.username) && typeof e.hasTotp === 'boolean' && typeof e.exact === 'boolean');
        return { entry: e.entry, db: e.db, dbName: e.dbName, title: e.title, username: e.username, hasTotp: e.hasTotp, exact: e.exact };
      }) };
    case 'credential':
      if (request.totp === true) {
        requireThat(string(reply.totp) && reply.username === undefined && reply.password === undefined);
        return { ...result, totp: reply.totp };
      }
      requireThat(string(reply.username) && string(reply.password) && reply.totp === undefined);
      return { ...result, username: reply.username, password: reply.password };
    case 'generate':
      requireThat(string(reply.password) && reply.password.length > 0);
      return { ...result, password: reply.password };
    case 'reveal': case 'unlock': case 'save': return result;
    default: throw new ProtocolError();
  }
}
