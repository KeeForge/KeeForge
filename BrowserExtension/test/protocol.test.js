import test from 'node:test';
import assert from 'node:assert/strict';
import { validateEnvelope, envelope, request, validateRequest, validateReply, base64, origin, OUTER_ERRORS, INNER_ERRORS } from '../src/protocol.js';
import { ENTRY, DB } from './mock-app.js';
const b = btoa('x'.repeat(32));
const fixtures = [
  ['host', { event: 'connected' }], ['host', { event: 'unavailable', reason: 'closed' }],
  ['host', { event: 'unavailable', reason: 'not-running' }],
  ['host', { cmd: 'launch' }, 'client'], ['host', { cmd: 'connect' }, 'client'],
  ['pair-commit', { commit: b, name: 'Browser' }], ['pair-key', { pub: b, eph: b }],
  ['pair-reveal', { pub: b, eph: b, nonce: b }], ['pair-result', { ok: true }],
  ['hello', { eph: b, app: '1' }], ['hello', { eph: b, client: 'a'.repeat(32) }, 'client'],
  ['msg', { n: 0, c: b }], ...OUTER_ERRORS.map(code => ['error', { code }])
];
for (const [t, fields, direction] of fixtures) {
  test(`strict envelope ${t} ${JSON.stringify(Object.keys(fields))} ${direction ?? 'app'} ${fields.code ?? fields.event ?? fields.cmd ?? ''}`, () => {
    const valid = envelope(t, fields);
    assert.equal(validateEnvelope({ ...valid, extra: 'ignored' }, direction).t, t);
    for (const key of ['v', 't', ...Object.keys(fields)]) {
      const missing = { ...valid }; delete missing[key];
      assert.throws(() => validateEnvelope(missing, direction));
      for (const value of [null, {}, [], false]) {
        if (value === valid[key]) continue;
        assert.throws(() => validateEnvelope({ ...valid, [key]: value }, direction));
      }
    }
  });
}
test('reject invalid envelope values and canonical base64', () => {
  for (const f of [null, [], 1, {}, { v: 2, t: 'error' }, envelope('unknown'), envelope('host', { event: 'other' }), envelope('host', { event: 'unavailable', reason: 'other' }), envelope('host', { cmd: 'other' }), envelope('error', { code: 'other' }), envelope('pair-result', { ok: false }), envelope('pair-commit', { commit: b, name: 'x'.repeat(65) }), envelope('hello', { eph: b, client: 'A'.repeat(32) })]) assert.throws(() => validateEnvelope(f));
  for (const c of ['x', '!!!!', 'eA', 'eB==', 'eA===', ' eA==', 'eA==\n']) assert.throws(() => base64(c));
  assert.throws(() => base64('eA==', 32));
  for (const n of [-1, 0.1, Number.MAX_SAFE_INTEGER + 1, NaN, '0']) assert.throws(() => validateEnvelope(envelope('msg', { n, c: b })));
  assert.throws(() => validateEnvelope(envelope('msg', { n: 0, c: '' })));
});
const requests = [request(1, 'status'), request(1, 'matches', { origin: 'https://example.com' }), request(1, 'credential', { entry: ENTRY, db: DB, origin: 'https://example.com' }), request(1, 'reveal', { entry: ENTRY, db: DB }), request(1, 'unlock', { db: DB }), request(1, 'credential', { entry: ENTRY, db: DB, origin: 'https://example.com', totp: true }), request(1, 'generate', { origin: 'https://example.com' }), request(1, 'save', { origin: 'https://example.com', username: '', password: 'secret' })];
const replies = [
  { app: '1', unlocked: 0, locked: 1 },
  { entries: [{ entry: ENTRY, db: DB, dbName: 'db', title: 'title', username: 'user', hasTotp: true, exact: true }], locked: 0 },
  { username: 'user', password: 'password' }, {}, {}, { totp: '123456' }, { password: 'generated' }, {}
];
for (const [i, req] of requests.entries()) {
  test(`strict inner ${req.type}${req.totp ? ' (code only)' : ''}`, () => {
    for (const key of Object.keys(req)) {
      if (key === 'totp' || (key === 'db' && req.type === 'unlock')) continue;
      const fields = { ...req }; delete fields[key];
      assert.throws(() => validateRequest(fields));
      assert.throws(() => validateRequest({ ...req, [key]: null }));
    }
    const reply = { id: 1, ok: true, ...replies[i] };
    assert.deepEqual(validateReply({ ...reply, extra: 'ignored' }, req), reply);
    for (const key of Object.keys(reply)) {
      const missing = { ...reply }; delete missing[key];
      assert.throws(() => validateReply(missing, req));
      assert.throws(() => validateReply({ ...reply, [key]: null }, req));
    }
    for (const error of INNER_ERRORS) assert.equal(validateReply({ id: 1, ok: false, error }, req).error, error);
    for (const invalid of [null, [], {}, { id: 2, ok: true }, { id: 1, ok: false, error: 'other' }, { id: 1, ok: 'true' }]) assert.throws(() => validateReply(invalid, req));
  });
}
test('inner edge failures and matches strips unknown fields', () => {
  assert.throws(() => request(-1, 'status'));
  assert.throws(() => request(0, 'other'));
  assert.throws(() => request(0, 'credential', { entry: ENTRY, db: DB, origin: 'https://example.com', totp: false }));
  assert.throws(() => request(0, 'unlock', { db: '' }));
  for (const key of Object.keys(replies[1].entries[0])) {
    const e = { ...replies[1].entries[0] }; delete e[key];
    assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: [e] }, requests[1]));
    assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...e, [key]: null }] }, requests[1]));
  }
  assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: Array(51).fill(replies[1].entries[0]) }, requests[1]));
  assert.throws(() => validateReply({ id: 1, ok: true, totp: 123 }, requests[5]));
  // A code-only reply carries the code alone; a password fill never carries a code.
  for (const extra of [{ username: 'a' }, { password: 'b' }, { username: 'a', password: 'b' }]) assert.throws(() => validateReply({ id: 1, ok: true, totp: '123456', ...extra }, requests[5]));
  assert.throws(() => validateReply({ id: 1, ok: true, username: 'a', password: 'b', totp: '123' }, requests[2]));
  assert.deepEqual(validateReply({ id: 1, ok: true, totp: '123456' }, requests[5]), { id: 1, ok: true, totp: '123456' });
  const result = validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...replies[1].entries[0], password: 'accidental-secret' }] }, requests[1]);
  assert.equal('password' in result.entries[0], false);
  for (const value of ['https://example.com/', 'https://example.com/path', 'http://example.com', 'null', 'file:///tmp/a', 'https://example.com:443']) assert.throws(() => origin(value));
});
test('numeric bounds, malformed UUIDs and wrong field value types are rejected', () => {
  for (const id of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1, '1', NaN, Infinity]) {
    assert.throws(() => request(id, 'status'));
    assert.throws(() => validateReply({ id, ok: true, ...replies[0] }, requests[0]));
  }
  for (const field of ['entry', 'db']) {
    for (const value of ['invalid', 1, false]) {
      assert.throws(() => request(1, 'credential', { ...requests[2], [field]: value }));
      assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...replies[1].entries[0], [field]: value }] }, requests[1]));
    }
  }
  for (const field of ['unlocked', 'locked']) for (const value of [-1, 1.5, Number.MAX_SAFE_INTEGER + 1, '1']) assert.throws(() => validateReply({ id: 1, ok: true, ...replies[0], [field]: value }, requests[0]));
  for (const value of [-1, 1.5, '1']) assert.throws(() => validateReply({ id: 1, ok: true, ...replies[1], locked: value }, requests[1]));
  for (const field of ['username', 'password']) assert.throws(() => validateReply({ id: 1, ok: true, ...replies[2], [field]: 1 }, requests[2]));
  assert.throws(() => validateReply({ id: 1, ok: true, entries: [null], locked: 0 }, requests[1]));
  assert.throws(() => validateReply({}, { id: 1, type: 'unknown' }));
  assert.throws(() => validateReply({ id: 1, ok: true }, { id: 1, type: 'unknown' }));
  for (const value of [0, 'true', null]) assert.throws(() => request(1, 'credential', { ...requests[2], totp: value }));
  for (const field of ['dbName', 'title', 'username', 'hasTotp']) assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...replies[1].entries[0], [field]: field === 'hasTotp' ? 'true' : false }] }, requests[1]));
});
test('request ids include zero and the largest exactly representable integer; exact is a required boolean', () => {
  for (const id of [0, Number.MAX_SAFE_INTEGER]) assert.equal(request(id, 'status').id, id);
  for (const exact of [true, false]) assert.equal(validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...replies[1].entries[0], exact }] }, requests[1]).entries[0].exact, exact);
  for (const exact of [undefined, null, 0, 'true']) assert.throws(() => validateReply({ id: 1, ok: true, locked: 0, entries: [{ ...replies[1].entries[0], exact }] }, requests[1]));
});
test('an app hello may list its optional features; an older app lists none', () => {
  assert.deepEqual(validateEnvelope(envelope('hello', { eph: b, app: '1', features: ['generate', 'save', 'future'] })).features, ['generate', 'save', 'future']);
  assert.equal(validateEnvelope(envelope('hello', { eph: b, app: '1' })).features, undefined);
  for (const features of [null, 'save', [1], {}, Array(17).fill('x')]) assert.throws(() => validateEnvelope(envelope('hello', { eph: b, app: '1', features })), JSON.stringify(features));
});
test('save requests bound their fields and need a password; generated and save replies carry only their own fields', () => {
  const save = fields => request(1, 'save', { origin: 'https://example.com', username: 'u', password: 'p', ...fields });
  assert.ok(save({ username: '😀'.repeat(1024), password: '😀'.repeat(1024) }), 'the limit counts characters');
  for (const fields of [{ password: '' }, { password: 'p'.repeat(1025) }, { username: 'u'.repeat(1025) }, { origin: 'http://example.com' }]) assert.throws(() => save(fields), JSON.stringify(fields).slice(0, 40));
  assert.throws(() => request(1, 'generate', { origin: 'https://example.com/path' }));
  assert.throws(() => validateReply({ id: 1, ok: true, password: '' }, requests[6]));
  assert.deepEqual(validateReply({ id: 1, ok: true, password: 'generated', username: 'stray' }, requests[6]), { id: 1, ok: true, password: 'generated' });
  assert.deepEqual(validateReply({ id: 1, ok: true, password: 'stray' }, requests[7]), { id: 1, ok: true });
  for (const error of ['exists', 'declined', 'save-failed']) assert.equal(validateReply({ id: 1, ok: false, error }, requests[7]).error, error);
});
