import test from 'node:test';
import assert from 'node:assert/strict';
import { Cipher, keyPair, publicBytes, clientKeys, iv, fromBase64, toBase64, dh } from '../src/crypto.js';
test('direction keys, authentication, nonce byte order and counter exhaustion', async () => {
  const c = await keyPair(), s = await keyPair(), ec = await keyPair(), es = await keyPair();
  const keys = await clientKeys(c, ec, await publicBytes(s), await publicBytes(es));
  const client = new Cipher(keys.c2s, keys.s2c), server = new Cipher(keys.s2c, keys.c2s);
  const frame = await client.seal({ message: 'hello' });
  assert.deepEqual(await server.open(frame), { message: 'hello' });
  await assert.rejects(server.open(frame), /bad-handshake/);
  await assert.rejects(new Cipher(keys.s2c, keys.s2c).open(frame));
  assert.deepEqual([...iv(0x010203040506)], [0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6]);
  for (const n of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1]) assert.throws(() => iv(n));
  client.sendCounter = Number.MAX_SAFE_INTEGER;
  const last = await client.seal({}); assert.equal(last.n, Number.MAX_SAFE_INTEGER);
  await assert.rejects(client.seal({}));
  await assert.rejects(dh(c.privateKey, new Uint8Array(32)));
  assert.deepEqual(fromBase64(toBase64(new Uint8Array([0, 1, 254, 255]))), new Uint8Array([0, 1, 254, 255]));
});
