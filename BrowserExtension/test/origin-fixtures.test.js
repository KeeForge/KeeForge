import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { origin, validateRequest } from '../src/protocol.js';

// The app's origin rules (TestFixtures/browser-bridge/README.md). The extension
// sends only what the browser serialized, so it refuses every origin that is
// not already in canonical form; the app accepts some of those. Each listed
// difference must still differ, so a change on either side shows up here.
const fixture = JSON.parse(await readFile(new URL('../../TestFixtures/browser-bridge/origins.json', import.meta.url), 'utf8'));
const stricter = new Set([
  'https://EXAMPLE.COM', 'https://Example.Com', 'http://LOCALHOST',
  'https://example.com:443', 'http://localhost:80', 'https://example.com:00443', 'https://example.com:99999999999999999999',
  'https://[2001:0DB8::1]', 'https://[::ffff:192.0.2.1]', 'https://0x7f.0.0.1', 'https://foo.1.2.3.4',
]);
// The app's URL parser refuses hosts longer than 2048 characters; browsers do not.
const looser = new Set([`https://${'a'.repeat(2045)}.com`]);

function accepts(value) {
  try { origin(value); } catch { return false; }
  assert.doesNotThrow(() => validateRequest({ id: 1, type: 'matches', origin: value }));
  return true;
}

test('origin fixtures: the extension agrees with the app except for the listed differences', () => {
  assert.equal(fixture.version, 1, 'unrecognised fixture version');
  const origins = new Set(fixture.cases.map(c => c.origin));
  for (const value of [...stricter, ...looser]) assert.ok(origins.has(value), `difference listed for a missing case: ${value.slice(0, 60)}`);
  for (const { origin: value, valid, note } of fixture.cases) {
    const expected = stricter.has(value) ? false : looser.has(value) ? true : valid;
    if (stricter.has(value)) assert.equal(valid, true, `${note}: listed as stricter but the app refuses it`);
    if (looser.has(value)) assert.equal(valid, false, `${note}: listed as looser but the app accepts it`);
    assert.equal(accepts(value), expected, `${JSON.stringify(value.slice(0, 60))} (${note})`);
  }
});
