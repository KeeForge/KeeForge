import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { findBrowser, findFirefox } from '../tools/chrome-cdp.mjs';

const home = '/Users/someone';
const fakeFs = (executables, folders = {}) => ({ isExecutable: path => executables.includes(path), list: dir => folders[dir] ?? [] });

test('an explicit browser is used as given and never falls back', () => {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  assert.deepEqual(findBrowser({ explicit: '/missing/Chrome', home, fs: fakeFs([chrome]) }), { browser: null, searched: ['/missing/Chrome'] });
  assert.equal(findBrowser({ explicit: chrome, home, fs: fakeFs([chrome]) }).browser, chrome);
});

test('standard applications come before the Chrome for Testing cache, newest cached version first', () => {
  const cache = `${home}/Library/Caches/KeeForge-E2E/chrome`;
  const cached = version => `${cache}/${version}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
  const folders = { [cache]: ['mac_arm-157.0.1', 'mac_arm-158.0.2'], [`${cache}/mac_arm-157.0.1`]: ['chrome-mac-arm64'], [`${cache}/mac_arm-158.0.2`]: ['chrome-mac-arm64'] };
  const edge = `${home}/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`;
  assert.equal(findBrowser({ home, fs: fakeFs([edge, cached('mac_arm-158.0.2')], folders) }).browser, edge);
  assert.equal(findBrowser({ home, fs: fakeFs([cached('mac_arm-157.0.1'), cached('mac_arm-158.0.2')], folders) }).browser, cached('mac_arm-158.0.2'));
  const none = findBrowser({ home, fs: fakeFs([]) });
  assert.equal(none.browser, null);
  assert.ok(none.searched.includes('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'));
  assert.ok(none.searched.some(path => path.startsWith(`${home}/Library/Caches/KeeForge-E2E/chrome/`)));
});

test('without a macOS browser the search ends with Chromium and Firefox commands on PATH; explicit Firefox never falls back', () => {
  const path = ['/usr/local/bin', '/usr/bin'];
  assert.equal(findBrowser({ home, fs: fakeFs(['/usr/bin/google-chrome', '/usr/bin/chromium']), path }).browser, '/usr/bin/google-chrome');
  assert.equal(findBrowser({ home, fs: fakeFs(['/usr/bin/chromium']) }).browser, null);
  assert.equal(findFirefox({ home, fs: fakeFs(['/usr/bin/firefox']), path }).browser, '/usr/bin/firefox');
  assert.equal(findFirefox({ home, fs: fakeFs(['/Applications/Firefox.app/Contents/MacOS/firefox', '/usr/bin/firefox']), path }).browser, '/Applications/Firefox.app/Contents/MacOS/firefox');
  assert.deepEqual(findFirefox({ explicit: '/missing/firefox', home, fs: fakeFs(['/usr/bin/firefox']), path }), { browser: null, searched: ['/missing/firefox'] });
});

test('the driver reports a missing browser at start-up and fails start with browser-missing', async t => {
  const driver = spawn(process.execPath, [new URL('../tools/e2e-browser.mjs', import.meta.url).pathname, '--host', '/bin/sh', '--browser', '/missing/Chrome'], { stdio: ['pipe', 'pipe', 'inherit'] });
  t.after(() => driver.kill());
  const lines = createInterface({ input: driver.stdout })[Symbol.asyncIterator]();
  const ready = JSON.parse((await lines.next()).value);
  assert.equal(ready.event, 'driver-ready');
  assert.equal(ready.browser, null);
  driver.stdin.write(JSON.stringify({ id: 1, cmd: 'start' }) + '\n');
  const reply = JSON.parse((await lines.next()).value);
  assert.equal(reply.done, false);
  assert.equal(reply.error, 'browser-missing');
  assert.match(reply.message, /\/missing\/Chrome/);
  driver.stdin.end();
  await once(driver, 'exit');
});
