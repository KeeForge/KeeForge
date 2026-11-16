// Expected vectors.json: { vectors: [{ name, client: {privateKey, publicKey}, app:
// {privateKey, publicKey}, clientEphemeral: {privateKey, publicKey}, appEphemeral:
// {privateKey, publicKey}, nonce, clientId, commitment, pairingCode, c2s, s2c,
// messages: [{direction: "c2s"|"s2c", n, plaintext: object, ciphertext}] }] }.
// All byte fields are padded standard base64; privateKey is raw 32-byte X25519.
// c2s/s2c are raw 32-byte AES keys; ciphertext includes the 16-byte GCM tag.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { clientId, commitment, pairingCode, clientKeys, Cipher, fromBase64, toBase64 } from '../src/crypto.js';
let vectors;
try { vectors = JSON.parse(await readFile(new URL('./vectors.json', import.meta.url), 'utf8')).vectors; }
catch (error) { if (error.code !== 'ENOENT') throw error; }
const url64 = bytes => toBase64(bytes).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
async function pair(value) {
  const pub = fromBase64(value.publicKey, 32);
  const privateKey = await crypto.subtle.importKey('jwk', { kty: 'OKP', crv: 'X25519', x: url64(pub), d: url64(fromBase64(value.privateKey, 32)), ext: true, key_ops: ['deriveBits'] }, 'X25519', false, ['deriveBits']);
  return { privateKey, publicKey: await crypto.subtle.importKey('raw', pub, 'X25519', true, []) };
}
test('Swift interoperability vectors', { skip: vectors === undefined ? 'vectors.json has not arrived from the Swift worker; cross-language verification pending' : false }, async () => {
  assert.ok(Array.isArray(vectors) && vectors.length > 0, 'Expected nonempty vectors array; reconcile shape with the Swift worker');
  for (const v of vectors) {
    const c = fromBase64(v.client.publicKey, 32), s = fromBase64(v.app.publicKey, 32);
    const ec = fromBase64(v.clientEphemeral.publicKey, 32), es = fromBase64(v.appEphemeral.publicKey, 32);
    assert.equal(await clientId(c), v.clientId, v.name);
    assert.equal(toBase64(await commitment(c, ec, fromBase64(v.nonce, 32))), v.commitment, v.name);
    assert.equal(await pairingCode(c, s, ec, es), v.pairingCode, v.name);
    const actual = await clientKeys(await pair(v.client), await pair(v.clientEphemeral), s, es);
    for (const direction of ['c2s', 's2c']) {
      const expected = await crypto.subtle.importKey('raw', fromBase64(v[direction], 32), 'AES-GCM', false, ['encrypt', 'decrypt']);
      const known = new Cipher(expected, expected), derived = new Cipher(actual[direction], actual[direction]);
      assert.deepEqual(await derived.seal({ vector: v.name }), await known.seal({ vector: v.name }));
    }
    assert.ok(v.messages.length > 0);
    for (const m of v.messages) {
      const cipher = new Cipher(actual[m.direction], actual[m.direction]);
      cipher.sendCounter = m.n; cipher.receiveCounter = m.n;
      const frame = await cipher.seal(m.plaintext);
      assert.equal(frame.c, m.ciphertext, v.name);
      assert.deepEqual(await cipher.open(frame), m.plaintext);
    }
  }
});
