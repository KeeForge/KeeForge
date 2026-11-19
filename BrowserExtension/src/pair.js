import { message, reason, localizePage } from './i18n.js';
import { browserName } from './browser-name.js';
localizePage();
const status = document.querySelector('#status'), code = document.querySelector('#code'), open = document.querySelector('#open');
const switchHint = document.querySelector('#switch'), glyph = document.querySelector('#state-icon');
let launch = false;
const show = name => { glyph.className = name ? `kf-icon kf-state-icon glyph-${name}` : 'kf-waiting'; };
open.addEventListener('click', async () => {
  if (!launch) { await start(); return; }
  open.disabled = true;
  try { const state = await chrome.runtime.sendMessage({ type: 'launchApp' }); if (state.state === 'unpaired' || state.state === 'ready') await start(); else failed(state.reason || 'not-running'); }
  catch { failed('unavailable'); }
  finally { open.disabled = false; }
});
function failed(error) {
  code.textContent = ''; switchHint.hidden = true; status.textContent = reason(error); show(error === 'not-running' || error === 'closed' ? 'power' : 'alert');
  launch = ['not-running', 'closed'].includes(error); open.textContent = message(launch ? 'openApp' : 'tryAgain'); open.hidden = false;
}
async function poll() {
  try {
    const state = await chrome.runtime.sendMessage({ type: 'getState' });
    if (state.state === 'ready') { code.textContent = ''; switchHint.hidden = true; status.textContent = message('paired'); show('check'); glyph.hidden = false; }
    else if (state.state === 'pairing') setTimeout(poll, 500);
    else failed(state.reason || (state.state === 'app-unavailable' ? 'not-running' : 'unavailable'));
  } catch { failed('unavailable'); }
}
async function start() {
  open.hidden = true; code.textContent = ''; switchHint.hidden = true; status.textContent = message('loading'); show(); glyph.hidden = false;
  const name = await browserName(navigator, message('browser')); document.querySelector('#browser').textContent = message('browserLabel', name);
  try {
    const result = await chrome.runtime.sendMessage({ type: 'startPairing', name });
    if (result.ok === false) { failed(result.error); return; }
    code.textContent = `${result.code.slice(0, 3)} ${result.code.slice(3)}`; status.textContent = message('compareCode'); switchHint.hidden = false; glyph.hidden = true; void poll();
  } catch { failed('unavailable'); }
}
void start();
