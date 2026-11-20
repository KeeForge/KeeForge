#!/usr/bin/env node
// Checks what tools/build.sh produced: each archive equals its unpacked copy, holds exactly the shipped files (no test
// pages, tools or development key), carries project.yml's MARKETING_VERSION, and contains every file it references.
import { readFile, readdir } from 'node:fs/promises';
import { inflateRawSync } from 'node:zlib';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('..', import.meta.url));
async function files(dir) {
  const found = [];
  for (const entry of await readdir(dir, { withFileTypes: true, recursive: true })) if (entry.isFile()) found.push(relative(dir, join(entry.parentPath, entry.name)).split('\\').join('/'));
  return found.sort();
}
function unzip(bytes) {
  const end = bytes.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  assert.ok(end >= 0, 'no end-of-central-directory record');
  const entries = new Map();
  for (let i = 0, at = bytes.readUInt32LE(end + 16); i < bytes.readUInt16LE(end + 10); ++i) {
    assert.equal(bytes.readUInt32LE(at), 0x02014b50, 'bad central directory');
    const method = bytes.readUInt16LE(at + 10), size = bytes.readUInt32LE(at + 20), nameLength = bytes.readUInt16LE(at + 28);
    const name = bytes.subarray(at + 46, at + 46 + nameLength).toString('utf8'), local = bytes.readUInt32LE(at + 42);
    const start = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28), data = bytes.subarray(start, start + size);
    assert.ok(!entries.has(name), `duplicate entry ${name}`);
    entries.set(name, method === 8 ? inflateRawSync(data) : data);
    at += 46 + nameLength + bytes.readUInt16LE(at + 30) + bytes.readUInt16LE(at + 32);
  }
  return entries;
}
const versions = [...new Set([...(await readFile(join(root, '..', 'project.yml'), 'utf8')).matchAll(/MARKETING_VERSION:\s*"([0-9.]+)"/g)].map(m => m[1]))];
assert.equal(versions.length, 1, 'expected exactly one MARKETING_VERSION in project.yml');
const source = JSON.parse(await readFile(join(root, 'manifest.json'), 'utf8'));
const shipped = ['manifest.json', 'popup.html', 'pair.html', 'inline.html', 'popup.css', 'pair.css', 'inline.css', 'theme.css',
  ...(await Promise.all(['src', '_locales', 'images'].map(async dir => (await files(join(root, dir))).map(f => `${dir}/${f}`)))).flat()].sort();
let checks = 0;
const check = (name, test) => { test(); ++checks; console.log(`PASS ${name}`); };
for (const browser of ['chrome', 'firefox']) {
  const dir = join(root, 'build', browser), archive = unzip(await readFile(join(root, 'build', `${browser}.zip`)));
  const unpacked = await files(dir);
  check(`${browser}: archive and unpacked copy hold the same files with the same bytes`, () => {
    assert.deepEqual([...archive.keys()].sort(), unpacked);
  });
  for (const name of unpacked) assert.deepEqual(archive.get(name), await readFile(join(dir, name)), `${browser}: ${name} differs between zip and unpacked copy`);
  check(`${browser}: exactly the shipped files (no test pages, tools, docs or package files)`, () => {
    assert.deepEqual(unpacked, shipped);
    assert.ok(unpacked.every(f => !/^(test|tools|build)\/|\.(mjs|md|sh)$|^package\.json$/.test(f)));
  });
  for (const name of unpacked.filter(f => f !== 'manifest.json')) assert.deepEqual(archive.get(name), await readFile(join(root, name)), `${browser}: ${name} differs from the source tree`);
  const manifest = JSON.parse(archive.get('manifest.json'));
  check(`${browser}: manifest is the source manifest without the development key, stamped ${versions[0]}`, () => {
    const expected = structuredClone(source);
    delete expected.key; expected.version = versions[0];
    if (browser === 'firefox') {
      for (const resource of expected.web_accessible_resources) delete resource.use_dynamic_url;
      for (const script of expected.content_scripts) delete script.world;
    }
    assert.deepEqual(manifest, expected);
    assert.ok(!archive.get('manifest.json').includes(source.key.slice(0, 40)));
  });
  const referenced = new Set([...Object.values(manifest.icons), ...Object.values(manifest.action.default_icon), manifest.action.default_popup, manifest.background.service_worker, ...manifest.background.scripts,
    ...manifest.content_scripts.flatMap(s => s.js), ...manifest.web_accessible_resources.flatMap(r => r.resources), `_locales/${manifest.default_locale}/messages.json`]);
  for (const name of unpacked.filter(f => /\.(html|css)$/.test(f))) for (const m of archive.get(name).toString('utf8').matchAll(/(?:src|href)="([^"]+)"|url\(['"]?([^'")]+)/g)) referenced.add(m[1] || m[2]);
  check(`${browser}: every file the manifest, pages and stylesheets reference is in the archive (${referenced.size})`, () => {
    for (const name of referenced) assert.ok(archive.has(name), `${browser}: missing ${name}`);
  });
}
console.log(`${checks} build checks passed`);
