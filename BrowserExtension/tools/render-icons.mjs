#!/usr/bin/env node
// Renders the toolbar/extension PNGs from the SVG sources; 16 and 32 use the pixel-grid variant.
// --check renders without writing and compares pixels with the committed PNGs.
import { readFile, writeFile } from 'node:fs/promises';
import { inflateSync } from 'node:zlib';
import { launchChrome } from './ui-chrome.mjs';
const root = new URL('../', import.meta.url);
const sources = { 16: 'images/icon-16.svg', 32: 'images/icon-16.svg', 48: 'images/icon.svg', 128: 'images/icon.svg' };
// Absorbs rounding noise (8 levels) and a few anti-aliased edge pixels (0.1%) if a Chrome/Skia update re-rasterizes
// edges; a colour change or a 2 px shape change exceeds it. A real drift fails here: re-render and commit the PNGs.
const tolerance = { channel: 8, pixels: 0.001 };
function pixels(png) {
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20), depth = png[24], type = png[25];
  if (depth !== 8 || ![2, 6].includes(type) || png[28]) throw Error('expected a non-interlaced 8-bit RGB(A) PNG');
  const chunks = [];
  for (let at = 8; at < png.length; at += 12 + png.readUInt32BE(at)) if (png.toString('latin1', at + 4, at + 8) === 'IDAT') chunks.push(png.subarray(at + 8, at + 8 + png.readUInt32BE(at)));
  const raw = inflateSync(Buffer.concat(chunks)), channels = type === 6 ? 4 : 3, stride = width * channels, out = Buffer.alloc(width * height * 4, 255);
  let previous = Buffer.alloc(stride);
  for (let y = 0; y < height; ++y) {
    const filter = raw[y * (stride + 1)], line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let x = 0; x < stride; ++x) {
      const a = x >= channels ? line[x - channels] : 0, b = previous[x], c = x >= channels ? previous[x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      line[x] = (line[x] + [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter]) & 255;
    }
    for (let x = 0; x < width; ++x) line.copy(out, (y * width + x) * 4, x * channels, x * channels + channels);
    previous = line;
  }
  return { width, height, data: out };
}
const browser = await launchChrome();
const check = process.argv.includes('--check');
let failed = 0;
try {
  const tab = await browser.tab();
  for (const [size, source] of Object.entries(sources)) {
    const svg = await readFile(new URL(source, root), 'utf8');
    await tab.call('Emulation.setDeviceMetricsOverride', { width: +size, height: +size, deviceScaleFactor: 1, mobile: false });
    await tab.call('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
    const { frameTree } = await tab.call('Page.getFrameTree');
    await tab.call('Page.setDocumentContent', { frameId: frameTree.frame.id, html: `<html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style></head><body>${svg}</body></html>` });
    const { data } = await tab.call('Page.captureScreenshot', { format: 'png', omitBackground: true, clip: { x: 0, y: 0, width: +size, height: +size, scale: 1 } });
    const file = new URL(`images/icon-${size}.png`, root), rendered = Buffer.from(data, 'base64');
    if (!check) { await writeFile(file, rendered); console.log(`images/icon-${size}.png`); continue; }
    const a = pixels(rendered), b = pixels(await readFile(file));
    let worst = 0, off = 0;
    if (a.width !== b.width || a.height !== b.height) off = Infinity;
    else for (let i = 0; i < a.data.length; i += 4) {
      // Premultiplied, so the colour of fully transparent pixels does not count.
      const delta = Math.max(Math.abs(a.data[i + 3] - b.data[i + 3]), ...[0, 1, 2].map(c => Math.abs(a.data[i + c] * a.data[i + 3] - b.data[i + c] * b.data[i + 3]) / 255));
      worst = Math.max(worst, delta); if (delta > tolerance.channel) ++off;
    }
    const ok = off <= tolerance.pixels * size * size;
    failed += !ok;
    console.log(`${ok ? 'PASS' : 'FAIL'} images/icon-${size}.png matches its SVG source (max channel delta ${worst}, ${off === Infinity ? 'size differs' : `${off} pixels beyond ${tolerance.channel}`})`);
  }
} finally { await browser.close(); }
if (failed) { console.error('Re-render with node tools/render-icons.mjs and commit the PNGs'); process.exitCode = 1; }
