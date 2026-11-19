#!/usr/bin/env node
// Renders the toolbar/extension PNGs from the SVG sources; 16 and 32 use the pixel-grid variant.
import { readFile, writeFile } from 'node:fs/promises';
import { launchChrome } from './ui-chrome.mjs';
const root = new URL('../', import.meta.url);
const sources = { 16: 'images/icon-16.svg', 32: 'images/icon-16.svg', 48: 'images/icon.svg', 128: 'images/icon.svg' };
const browser = await launchChrome();
try {
  const tab = await browser.tab();
  for (const [size, source] of Object.entries(sources)) {
    const svg = await readFile(new URL(source, root), 'utf8');
    await tab.call('Emulation.setDeviceMetricsOverride', { width: +size, height: +size, deviceScaleFactor: 1, mobile: false });
    await tab.call('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
    const { frameTree } = await tab.call('Page.getFrameTree');
    await tab.call('Page.setDocumentContent', { frameId: frameTree.frame.id, html: `<html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style></head><body>${svg}</body></html>` });
    const { data } = await tab.call('Page.captureScreenshot', { format: 'png', omitBackground: true, clip: { x: 0, y: 0, width: +size, height: +size, scale: 1 } });
    await writeFile(new URL(`images/icon-${size}.png`, root), Buffer.from(data, 'base64'));
    console.log(`images/icon-${size}.png`);
  }
} finally { await browser.close(); }
