#!/usr/bin/env node
// Content scripts are classic scripts; keep the serialized fill implementation identical without a bundler.
import { readFile, writeFile } from 'node:fs/promises';
import { fillDocument } from '../src/fill.js';
const path = new URL('../src/content.js', import.meta.url);
const source = await readFile(path, 'utf8');
const updated = source.replace(/(?<=\/\/ BEGIN shared fillDocument\n)[\s\S]*?(?=\n\/\/ END shared fillDocument)/, fillDocument.toString());
if (process.argv.includes('--check')) {
  if (updated !== source) throw Error('Run node tools/sync-content.mjs after changing fillDocument');
} else await writeFile(path, updated);
