import test from 'node:test';
import assert from 'node:assert/strict';
import { browserName } from '../src/browser-name.js';
test('browser label uses available brands and UA, with optional Brave detection and fallback', async () => {
  for (const [userAgent, expected] of [['Firefox/130', 'Firefox'], ['Chrome/133 Edg/133', 'Edge'], ['Chrome/133 Vivaldi/7', 'Vivaldi'], ['Chrome/133 Arc/1', 'Arc'], ['Chrome/133', 'Chrome'], ['', 'Browser']]) assert.equal(await browserName({ userAgent }), expected);
  assert.equal(await browserName({ userAgent: 'Chrome', brave: { isBrave: async () => true } }), 'Brave');
  assert.equal(await browserName({ userAgent: '', userAgentData: { brands: [{ brand: 'Brave' }] } }), 'Brave');
});
