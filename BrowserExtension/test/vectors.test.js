import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { clientId, commitment, pairingCode, clientKeys, Cipher, fromBase64, toBase64 } from '../src/crypto.js';
const v = JSON.parse(await readFile(new URL('./vectors.json', import.meta.url), 'utf8'));
const url64 = bytes => toBase64(bytes).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
async function pair(prefix) {
  const pub = fromBase64(v.inputs[`${prefix}_pub`], 32);
  const privateKey = await crypto.subtle.importKey('jwk', { kty: 'OKP', crv: 'X25519', x: url64(pub), d: url64(fromBase64(v.inputs[`${prefix}_private`], 32)), ext: true, key_ops: ['deriveBits'] }, 'X25519', false, ['deriveBits']);
  return { privateKey, publicBytes: pub };
}
test('real Swift vectors: identity, commitment, code, keys and both wire directions', async () => {
  assert.equal(v.version, 1, 'unrecognised vector version');
  const bytes = name => fromBase64(v.inputs[name], 32);
  const c = bytes('C_pub'), s = bytes('S_pub'), ec = bytes('ec_pub'), es = bytes('es_pub');
  assert.equal(await clientId(c), v.clientID, 'clientID');
  assert.equal(toBase64(await commitment(c, ec, bytes('nonce'))), v.commitment, 'commitment');
  assert.equal(await pairingCode(c, s, ec, es), v.pairingCode, 'pairingCode');
  const keys = await clientKeys(await pair('C'), await pair('ec'), s, es);
  for (const direction of ['c2s', 's2c']) {
    const expected = await crypto.subtle.importKey('raw', fromBase64(v[`k_${direction}`], 32), 'AES-GCM', false, ['encrypt', 'decrypt']);
    // Non-extractable derived keys are compared by their deterministic AES-GCM output.
    assert.deepEqual(await new Cipher(keys[direction], keys[direction]).seal({ keyCheck: true }), await new Cipher(expected, expected).seal({ keyCheck: true }), `k_${direction}`);
    assert.ok(Array.isArray(v[direction]) && v[direction].length > 0, `${direction} records missing`);
    const cipher = new Cipher(keys[direction], keys[direction]);
    for (const record of v[direction]) {
      const plaintext = JSON.parse(record.plaintext);
      assert.equal(JSON.stringify(plaintext), record.plaintext, `${direction} plaintext serialization`);
      assert.deepEqual(await cipher.seal(plaintext), record.envelope, `${direction} envelope ${record.envelope.n}`);
      assert.deepEqual(await cipher.open(record.envelope), plaintext, `${direction} open ${record.envelope.n}`);
      const frame = Buffer.from(record.frameBase64, 'base64');
      assert.equal(frame.readUInt32LE(0), frame.length - 4);
      assert.deepEqual(JSON.parse(frame.subarray(4).toString('utf8')), record.envelope);
    }
  }
});
