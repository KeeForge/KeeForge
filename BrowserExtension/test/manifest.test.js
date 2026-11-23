import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
const sites = ['https://*/*', 'http://localhost/*', 'http://127.0.0.1/*', 'http://[::1]/*'];
const icons = { 16: 'images/icon-16.png', 32: 'images/icon-32.png', 48: 'images/icon-48.png', 128: 'images/icon-128.png' };

test('manifest grants exactly the documented permissions and host access', () => {
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.permissions, ['nativeMessaging', 'activeTab', 'scripting', 'storage']);
  assert.deepEqual(manifest.host_permissions, sites);
  for (const key of ['optional_permissions', 'optional_host_permissions', 'externally_connectable', 'sandbox', 'update_url']) assert.equal(manifest[key], undefined, key);
});

test('manifest content script, web-accessible resources and CSP are exact', () => {
  assert.deepEqual(manifest.content_scripts, [{ matches: sites, js: ['src/content.js'], all_frames: true, run_at: 'document_start', world: 'ISOLATED' }]);
  assert.deepEqual(manifest.web_accessible_resources, [{ resources: ['inline.html'], matches: sites, use_dynamic_url: true }]);
  assert.deepEqual(manifest.content_security_policy, { extension_pages: "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; object-src 'none'; connect-src 'none'; base-uri 'none'; frame-ancestors https: http://localhost:* http://127.0.0.1:* http://[::1]:*" });
});

test('manifest browser versions, ids, background and action', () => {
  assert.equal(manifest.minimum_chrome_version, '133');
  assert.deepEqual(manifest.browser_specific_settings, { gecko: { id: 'browser-extension@keeforge.com', strict_min_version: '130.0' } });
  // The build stamps project.yml's MARKETING_VERSION; the source keeps a placeholder.
  assert.equal(manifest.version, '0.0.0');
  assert.match(manifest.key, /^MIIBIjAN/);
  assert.deepEqual(manifest.background, { service_worker: 'src/background.js', scripts: ['src/background.js'], type: 'module' });
  assert.deepEqual(manifest.action, { default_title: '__MSG_actionTitle__', default_popup: 'popup.html', default_icon: icons });
  assert.deepEqual(manifest.icons, icons);
  assert.equal(manifest.default_locale, 'en');
});

test('every file the manifest and extension pages reference exists; pages load only module scripts', async () => {
  const referenced = new Set([...Object.values(icons), manifest.action.default_popup, manifest.background.service_worker, ...manifest.content_scripts.flatMap(s => s.js), ...manifest.web_accessible_resources.flatMap(r => r.resources), `_locales/${manifest.default_locale}/messages.json`]);
  for (const page of ['popup.html', 'pair.html', 'inline.html']) {
    const html = await readFile(new URL(page, root), 'utf8');
    for (const [, tag, attributes] of html.matchAll(/<(script|link|img)\b([^>]*)>/g)) {
      const url = attributes.match(/\b(?:src|href)="([^"]+)"/)?.[1];
      assert.ok(url && !/^[a-z]+:|^\/\//i.test(url), `${page}: ${tag} must load a packaged file`);
      if (tag === 'script') assert.match(attributes, /type="module"/, `${page}: ${url}`);
      referenced.add(url);
    }
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/, `${page}: no inline script`);
  }
  for (const sheet of ['theme.css', 'popup.css', 'pair.css', 'inline.css']) for (const [, url] of (await readFile(new URL(sheet, root), 'utf8')).matchAll(/url\(['"]?([^'")]+)/g)) referenced.add(url);
  for (const file of referenced) await access(new URL(file, root));
});
