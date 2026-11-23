#!/usr/bin/env node
// Uses the shipped pages and renderers; only runtime replies and locale lookup are stubbed.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { launchChrome, delay } from './ui-chrome.mjs';
import { extensionDir } from './chrome-cdp.mjs';
import { layoutProbe } from './layout-probe.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const out = resolve(process.argv[2] || join(root, 'build/screenshots'));
await mkdir(out, { recursive: true });
const browser = await launchChrome();
const records = [];
const entries = [
  { entry: '1', db: 'a', dbName: 'Personal', title: 'Example account', username: 'alex@example.com', hasTotp: true, exact: true },
  { entry: '2', db: 'b', dbName: 'Work', title: 'A very long work account title that must truncate safely', username: 'alexandra.long-account-name@example.com', hasTotp: false, exact: true },
  { entry: '3', db: 'a', dbName: 'Personal', title: 'Other account', username: 'alex@accounts.example.com', hasTotp: true, exact: false }
];
const popupStates = ['matches', 'host-missing', 'app-unavailable', 'unpaired', 'pairing', 'locked', 'empty', 'bad-origin', 'no-fields', 'confirm', 'error', 'loading'];
const pairStates = ['comparison', 'success', 'declined', 'timeout', 'busy', 'app-unavailable', 'loading', 'host-missing', 'error'];
function stub({ state, locale, messages, count = 0 }) {
  const entryList = count ? Array.from({ length: count }, (_, i) => ({ ...entries[i % entries.length], entry: String(i), exact: true })) : entries;
  return `(() => {
    const messages = ${JSON.stringify(messages)}, state = ${JSON.stringify(state)};
    chrome.i18n.getUILanguage = () => ${JSON.stringify(locale)};
    chrome.i18n.getMessage = (key, substitutions) => { let value = messages[key]?.message || key; for (const [i, item] of (Array.isArray(substitutions) ? substitutions : [substitutions]).entries()) value = value.replaceAll('$' + (i + 1), item ?? ''); return value; };
    chrome.runtime.sendMessage = async request => {
      if (request.type === 'startPairing') {
        if (state === 'loading') return new Promise(() => {});
        const errors = { declined: 'pairing-declined', timeout: 'timeout', busy: 'pairing-busy', 'app-unavailable': 'not-running', 'host-missing': 'host-missing', error: 'unavailable' };
        return errors[state] ? { ok: false, error: errors[state] } : { code: '084291' };
      }
      if (request.type === 'getState') {
        if (state === 'loading') return new Promise(() => {});
        if (state === 'success') return { state: 'ready' };
        if (state === 'comparison') return { state: 'pairing' };
        return ['host-missing', 'app-unavailable', 'unpaired', 'pairing'].includes(state) ? { state } : state === 'error' ? { state: 'error', reason: 'disconnected' } : { state: 'ready' };
      }
      if (request.type === 'getTarget') return ['bad-origin', 'no-fields'].includes(state) ? { ok: false, error: state } : { tabId: 1, frameId: 2, origin: 'https://accounts.example.com', token: 'fixture' };
      if (request.type === 'getMatches') return { entries: ['empty', 'locked'].includes(state) ? [] : ${JSON.stringify(entryList)}, locked: state === 'locked' ? 1 : 0 };
      if (request.type === 'fill') return state === 'done' ? { ok: true } : new Promise(() => {});
      return { ok: true };
    };
    window.close = () => {};
  })();`;
}
async function settle(tab, ready) {
  for (let i = 0; i < 100; ++i) { if (await tab.evaluate(`document.readyState === 'complete' && !!(${ready})`).catch(() => false)) return; await delay(30); }
  throw new Error(`Page never became ready: ${ready}`);
}
const problems = [];
async function screenshot(name, tab, check, layout = true) {
  await delay(70);
  if (layout) for (const problem of await tab.evaluate(layoutProbe)) { problems.push(`${name}: ${problem}`); console.log(`FAIL ${name}: ${problem}`); }
  const { data } = await tab.call('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(out, `${name}.png`), Buffer.from(data, 'base64'));
  records.push({ file: `${name}.png`, check });
}
try {
  const { id } = await browser.send('Extensions.loadUnpacked', { path: extensionDir(root) });
  console.log(`Loaded extension ${id}`);
  for (const scheme of ['light', 'dark']) {
    for (const locale of ['en', 'de', 'ja', 'ru', 'fr', 'es', 'it', 'zh_CN', 'zh_TW']) {
      const messages = JSON.parse(await readFile(join(root, '_locales', locale, 'messages.json'), 'utf8'));
      const states = locale === 'en' ? popupStates : ['de', 'ja', 'ru'].includes(locale) ? ['matches', 'host-missing', 'pairing'] : ['matches', 'host-missing'];
      for (const state of states) {
        const tab = await browser.tab();
        try {
          await tab.call('Emulation.setDeviceMetricsOverride', { width: 340, height: 600, deviceScaleFactor: 2, mobile: false });
          await tab.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: 'reduce' }] });
          await tab.call('Page.addScriptToEvaluateOnNewDocument', { source: stub({ state, locale, messages }) });
          await tab.call('Page.navigate', { url: `chrome-extension://${id}/popup.html` });
          await settle(tab, state === 'loading' ? "document.querySelector('#status').textContent" : state === 'matches' || state === 'confirm' ? "document.querySelector('.login')" : "document.querySelector('#state-icon').className !== 'kf-waiting'");
          if (state === 'confirm') await tab.evaluate(`document.querySelector('.login').click()`);
          if (state === 'matches') await tab.evaluate(`document.querySelector('.login').focus()`);
          const height = await tab.evaluate('Math.ceil(document.querySelector("main").getBoundingClientRect().height)');
          await tab.call('Emulation.setDeviceMetricsOverride', { width: 340, height: Math.max(120, height), deviceScaleFactor: 2, mobile: false });
          await screenshot(`popup-${state}-${locale}-${scheme}`, tab, state === 'matches' ? 'Row hierarchy, truncation, group spacing, code and reveal actions, keyboard focus.' : 'State glyph, readable wrapped copy, primary action and unclipped panel.');
        } finally { await tab.close(); }
      }
      if (locale !== 'en' && !['de', 'ja', 'ru'].includes(locale)) continue;
      for (const state of locale === 'en' ? pairStates : ['comparison', 'busy']) {
        const tab = await browser.tab();
        try {
          await tab.call('Emulation.setDeviceMetricsOverride', { width: 720, height: 640, deviceScaleFactor: 2, mobile: false });
          await tab.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
          await tab.call('Page.addScriptToEvaluateOnNewDocument', { source: stub({ state, locale, messages }) });
          await tab.call('Page.navigate', { url: `chrome-extension://${id}/pair.html` });
          await delay(state === 'success' ? 700 : 150);
          await screenshot(`pair-${state}-${locale}-${scheme}`, tab, 'Centered card, app identity, browser label, grouped code or terminal copy; no clipping.');
        } finally { await tab.close(); }
      }
    }
    const tab = await browser.tab();
    try {
      await tab.call('Page.navigate', { url: `chrome-extension://${id}/popup.html` });
      await delay(120);
      // The preview CSS is supplied through CDP, never added to a shipped page.
      // A toolbar strip with the 16 px action icon (srcset as Chrome picks it), then each PNG at its native device pixels.
      const toolbar = scheme === 'light' ? ['#dee1e6', '#ffffff', '#f1f3f4'] : ['#1f1f1f', '#35363a', '#282828'];
      for (const scale of [1, 2]) {
        await tab.call('Emulation.setDeviceMetricsOverride', { width: 320, height: 210, deviceScaleFactor: scale, mobile: false });
        await tab.evaluate(`(() => {
          const img = (src, size, srcset) => Object.assign(document.createElement('img'), { src, width: size, height: size, ...(srcset ? { srcset } : {}) });
          const bar = document.createElement('div'); bar.className = 'bar';
          const omnibox = document.createElement('div'); omnibox.className = 'omnibox';
          bar.append(omnibox, img('images/icon-16.png', 16, 'images/icon-16.png 1x, images/icon-32.png 2x'));
          const sizes = document.createElement('div'); sizes.className = 'sizes';
          for (const size of [16, 32, 48, 128]) sizes.append(img('images/icon-' + size + '.png', size / ${scale}));
          document.body.replaceChildren(bar, sizes);
        })()`);
        await tab.call('CSS.enable').catch(async () => { await tab.call('DOM.enable'); await tab.call('CSS.enable'); });
        const { frameTree } = await tab.call('Page.getFrameTree');
        const { styleSheetId } = await tab.call('CSS.createStyleSheet', { frameId: frameTree.frame.id });
        await tab.call('CSS.setStyleSheetText', { styleSheetId, text: `html,body{width:auto;height:100%;margin:0;background:${toolbar[0]}}body{display:block;padding:0}.bar{display:flex;align-items:center;gap:12px;height:40px;padding:0 12px;background:${toolbar[1]}}.omnibox{flex:1;height:28px;border-radius:14px;background:${toolbar[2]}}.sizes{display:flex;align-items:end;gap:16px;padding:14px 12px}img{display:block}` });
        await delay(100);
        await screenshot(`icons-${scheme}-${scale}x`, tab, 'Toolbar-size icon beside an omnibox, then the 16/32/48/128 PNGs at native pixels; key legible, corners transparent.', false);
      }
    } finally { await tab.close(); }
  }
  // Stress the bounded list and confirm the header stays outside its scroll container.
  const tab = await browser.tab();
  try {
    const messages = JSON.parse(await readFile(join(root, '_locales/en/messages.json'), 'utf8'));
    await tab.call('Emulation.setDeviceMetricsOverride', { width: 340, height: 600, deviceScaleFactor: 2, mobile: false });
    await tab.call('Page.addScriptToEvaluateOnNewDocument', { source: stub({ state: 'matches', locale: 'en', messages, count: 50 }) });
    await tab.call('Page.navigate', { url: `chrome-extension://${id}/popup.html` }); await settle(tab, "document.querySelector('.login')");
    await screenshot('popup-50-rows-top', tab, '50 rows contained in the scrolling panel; fixed header.');
    await tab.evaluate('document.querySelectorAll(".login")[49].focus()');
    const headerTop = await tab.evaluate('document.querySelector("header").getBoundingClientRect().top');
    if (headerTop !== 0) throw new Error(`Header moved to ${headerTop} when the last row took focus`);
    await screenshot('popup-50-rows-bottom', tab, 'Last row reachable by focus, labels truncate, header stays visible.');
  } finally { await tab.close(); }
  // Pointer hover and keyboard selection, driven through real input events.
  for (const scheme of ['light', 'dark']) {
    const tab = await browser.tab();
    try {
      const messages = JSON.parse(await readFile(join(root, '_locales/en/messages.json'), 'utf8'));
      await tab.call('Emulation.setDeviceMetricsOverride', { width: 340, height: 330, deviceScaleFactor: 2, mobile: false });
      await tab.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
      await tab.call('Page.addScriptToEvaluateOnNewDocument', { source: stub({ state: 'matches', locale: 'en', messages }) });
      await tab.call('Page.navigate', { url: `chrome-extension://${id}/popup.html` }); await settle(tab, "document.querySelector('.login')");
      const key = async (key, code, keyCode) => { for (const type of ['rawKeyDown', 'keyUp']) await tab.call('Input.dispatchKeyEvent', { type, key, code, windowsVirtualKeyCode: keyCode }); };
      // Headless Chrome does not update :hover from synthetic mouse moves, so force the pseudo-class.
      await tab.call('DOM.enable'); await tab.call('CSS.enable');
      const { root: documentNode } = await tab.call('DOM.getDocument');
      const { nodeIds } = await tab.call('DOM.querySelectorAll', { nodeId: documentNode.nodeId, selector: '.kf-row' });
      await tab.call('CSS.forcePseudoState', { nodeId: nodeIds[1], forcedPseudoClasses: ['hover'] });
      await screenshot(`popup-matches-hover-${scheme}`, tab, 'Forced :hover on an unselected row shows the hover fill and its quiet action; first row stays selected.');
      await tab.call('CSS.forcePseudoState', { nodeId: nodeIds[1], forcedPseudoClasses: [] });
      await key('ArrowDown', 'ArrowDown', 40);
      await key('Tab', 'Tab', 9);
      await screenshot(`popup-matches-keyboard-${scheme}`, tab, 'ArrowDown moved the selection; Tab moved focus to the row action with a visible ring.');
    } finally { await tab.close(); }
  }
  await writeFile(join(out, 'screenshots.json'), JSON.stringify(records, null, 2) + '\n');
  console.log(`${records.length} screenshots saved to ${out}; ${records.length - 4 - new Set(problems.map(p => p.split(':')[0])).size} of ${records.length - 4} page captures passed the layout and contrast checks`);
  if (problems.length) process.exitCode = 1;
} finally { await browser.close(); }
