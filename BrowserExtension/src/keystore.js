import { staticKeyPair } from './crypto.js';

// Storage implements read(), write(record), clear(); one record is committed atomically.
export class IndexedDBStorage {
  constructor(indexedDB = globalThis.indexedDB) { this.indexedDB = indexedDB; }
  async transaction(mode, action) {
    const db = await new Promise((resolve, reject) => {
      const opening = this.indexedDB.open('keeforge-pairing', 1);
      opening.onupgradeneeded = () => opening.result.createObjectStore('keys');
      opening.onsuccess = () => resolve(opening.result);
      opening.onerror = () => reject(opening.error);
    });
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction('keys', mode);
        const operation = action(tx.objectStore('keys'));
        tx.oncomplete = () => resolve(operation.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error ?? new Error('storage-aborted'));
      });
    } finally { db.close(); }
  }
  read() { return this.transaction('readonly', store => store.get('pairing')); }
  write(record) { return this.transaction('readwrite', store => store.put(record, 'pairing')); }
  clear() { return this.transaction('readwrite', store => store.clear()); }
}
export class KeyStore {
  constructor(storage = new IndexedDBStorage()) { this.storage = storage; this.queue = Promise.resolve(); }
  serial(operation) {
    const result = this.queue.then(operation);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
  load() {
    return this.serial(async () => {
      let record = await this.storage.read();
      if (!record) { record = { client: await staticKeyPair(), app: null }; await this.storage.write(record); }
      return record;
    });
  }
  pair(app) {
    return this.serial(async () => {
      const record = await this.storage.read();
      if (!record) throw new Error('pairing-forgotten');
      await this.storage.write({ ...record, app: new Uint8Array(app) });
    });
  }
  forget() { return this.serial(() => this.storage.clear()); }
}
