import { base64, envelope, integer, requireThat } from './protocol.js';
export const utf8 = value => new TextEncoder().encode(value);
export function concat(...arrays) {
  const result = new Uint8Array(arrays.reduce((n, a) => n + a.length, 0));
  let offset = 0;
  for (const a of arrays) { result.set(a, offset); offset += a.length; }
  return result;
}
export function toBase64(bytes) {
  let text = '';
  for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte);
  return btoa(text);
}
export const fromBase64 = base64;
export const random = () => crypto.getRandomValues(new Uint8Array(32));
export const keyPair = () => crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
export const publicBytes = async pair => pair.publicBytes ? new Uint8Array(pair.publicBytes) : new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
export async function staticKeyPair() {
  const generated = await keyPair();
  const bytes = await publicBytes(generated);
  // WebCrypto generates an exportable public half even when extractable is false.
  const publicKey = await crypto.subtle.importKey('raw', bytes, 'X25519', false, []);
  return { privateKey: generated.privateKey, publicKey, publicBytes: bytes };
}
export const hash = async bytes => new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
export async function clientId(pub) { return [...(await hash(pub)).slice(0, 16)].map(b => b.toString(16).padStart(2, '0')).join(''); }
export const commitment = (c, ec, nonce) => hash(concat(c, ec, nonce));
export async function pairingCode(c, s, ec, es) {
  const digest = await hash(concat(utf8('KeeForge browser pairing v1'), c, s, ec, es));
  return String(new DataView(digest.buffer).getUint32(0, false) % 1000000).padStart(6, '0');
}
export async function dh(privateKey, pub) {
  const key = await crypto.subtle.importKey('raw', pub, 'X25519', false, []);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: key }, privateKey, 256));
}
export async function schedule(ikm, c, s, ec, es) {
  const salt = await hash(concat(utf8('KeeForge browser bridge v1'), ec, es, c, s));
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveKey']);
  const derive = info => crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt, info: utf8(info) }, key, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  try { return { c2s: await derive('c2s'), s2c: await derive('s2c') }; }
  finally { ikm.fill(0); }
}
export async function clientKeys(c, ec, s, es) {
  const parts = await Promise.all([dh(ec.privateKey, es), dh(c.privateKey, es), dh(ec.privateKey, s)]);
  try { return await schedule(concat(...parts), await publicBytes(c), s, await publicBytes(ec), es); }
  finally { parts.forEach(p => p.fill(0)); }
}
export function iv(n) {
  requireThat(integer(n), 'bad-handshake');
  const bytes = new Uint8Array(12);
  new DataView(bytes.buffer).setBigUint64(4, BigInt(n), false);
  return bytes;
}
export class Cipher {
  constructor(sendKey, receiveKey) { this.sendKey = sendKey; this.receiveKey = receiveKey; this.sendCounter = 0; this.receiveCounter = 0; }
  async seal(message) {
    const n = this.sendCounter;
    const nonce = iv(n);
    this.sendCounter += 1;
    const plaintext = utf8(JSON.stringify(message));
    try {
      const c = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: utf8('msg'), tagLength: 128 }, this.sendKey, plaintext);
      return envelope('msg', { n, c: toBase64(c) });
    } finally { plaintext.fill(0); }
  }
  async open(frame) {
    requireThat(frame.n === this.receiveCounter, 'bad-handshake');
    let plaintext;
    try {
      plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv(frame.n), additionalData: utf8('msg'), tagLength: 128 }, this.receiveKey, fromBase64(frame.c)));
      const message = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plaintext));
      this.receiveCounter += 1;
      return message;
    } catch { requireThat(false, 'bad-handshake'); }
    finally { plaintext?.fill(0); }
  }
}
