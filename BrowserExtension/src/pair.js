import { message, reason, localizePage } from './i18n.js';
import { browserName } from './browser-name.js';
localizePage();
const status = document.querySelector('#status'), code = document.querySelector('#code'), open = document.querySelector('#open');
open.textContent = message('openApp');
open.addEventListener('click', async () => {
  open.disabled = true;
  try { const state = await chrome.runtime.sendMessage({ type: 'launchApp' }); if (state.state === 'unpaired' || state.state === 'ready') await start(); else failed(state.reason || 'not-running'); }
  catch { failed('unavailable'); }
  finally { open.disabled = false; }
});
function failed(error) { code.textContent = ''; status.textContent = reason(error); open.hidden = !['not-running', 'closed'].includes(error); }
async function poll() {
  try {
    const state = await chrome.runtime.sendMessage({ type: 'getState' });
    if (state.state === 'ready') { code.textContent = ''; status.textContent = message('paired'); }
    else if (state.state === 'pairing') setTimeout(poll, 500);
    else failed(state.reason || (state.state === 'app-unavailable' ? 'not-running' : 'unavailable'));
  } catch { failed('unavailable'); }
}
async function start() {
  open.hidden = true; code.textContent = ''; status.textContent = message('loading');
  const name = await browserName(navigator, message('browser')); document.querySelector('#browser').textContent = message('browserLabel', name);
  try {
    const result = await chrome.runtime.sendMessage({ type: 'startPairing', name });
    if (result.ok === false) { failed(result.error); return; }
    code.textContent = `${result.code.slice(0, 3)} ${result.code.slice(3)}`; status.textContent = message('compareCode'); void poll();
  } catch { failed('unavailable'); }
}
void start();
