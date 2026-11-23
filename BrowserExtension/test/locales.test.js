import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
const root = new URL('../_locales/', import.meta.url);
const read = async locale => JSON.parse(await readFile(new URL(`${locale}/messages.json`, root), 'utf8'));
test('all nine locales have exactly the English keys, nonempty messages and matching substitutions', async () => {
  const locales = ['en', 'de', 'fr', 'es', 'zh_CN', 'zh_TW', 'ja', 'it', 'ru'].sort();
  assert.deepEqual((await readdir(root)).sort(), locales);
  const en = await read('en'), keys = Object.keys(en).sort();
  for (const locale of locales) {
    const messages = await read(locale); assert.deepEqual(Object.keys(messages).sort(), keys, locale);
    for (const key of keys) { assert.ok(typeof messages[key].message === 'string' && messages[key].message.trim(), `${locale}/${key}`); assert.deepEqual(messages[key].message.match(/\$\d/g)?.sort(), en[key].message.match(/\$\d/g)?.sort(), `${locale}/${key} substitutions`); }
  }
});
