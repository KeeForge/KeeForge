import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const sources = Object.fromEntries(await Promise.all((await readdir(new URL('src/', root))).filter(f => f.endsWith('.js')).map(async f => [f, await readFile(new URL(`src/${f}`, root), 'utf8')])));

test('no packages: package.json declares no dependencies and sources import only sibling modules', async () => {
  assert.deepEqual(Object.keys(JSON.parse(await readFile(new URL('package.json', root), 'utf8'))).sort(), ['scripts', 'type']);
  let imports = 0;
  for (const [file, source] of Object.entries(sources)) for (const m of source.matchAll(/\bimport\s*(?:[^'"()]*?\bfrom\s*)?['"]([^'"]+)['"]|\bimport\(\s*['"]([^'"]+)/g)) { ++imports; assert.match(m[1] ?? m[2], /^\.\/[\w-]+\.js$/, `${file}: ${m[0]}`); }
  assert.ok(imports > 10);
});

test('the content script is a classic, self-contained script', () => {
  assert.doesNotMatch(sources['content.js'], /^\s*(import|export)\b|\bimport\(/m);
});

test('no logging, dynamic code or HTML injection in shipped sources', () => {
  for (const [file, source] of Object.entries(sources)) assert.doesNotMatch(source, /\bconsole\.|\beval\(|new Function\b|\.innerHTML\b|\.outerHTML\s*=|insertAdjacentHTML|document\.write/, file);
});

test('the toolbar icon, badge and title never change at run time', () => {
  for (const [file, source] of Object.entries(sources)) assert.doesNotMatch(source, /\.(setIcon|setBadgeText|setBadgeBackgroundColor|setTitle)\(/, file);
});

test('only the native port posts messages; no extension page or the content script posts to a window', () => {
  for (const [file, source] of Object.entries(sources)) if (file !== 'connection.js') assert.doesNotMatch(source, /postMessage/, file);
  assert.equal(sources['connection.js'].match(/postMessage/g).length, 1);
});
