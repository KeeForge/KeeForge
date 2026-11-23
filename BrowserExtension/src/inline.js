import { message, reason, localizePage } from './i18n.js';
import { loginRow, renderGroups } from './rows.js';
localizePage();
const token = location.hash.slice(1), embedded = window.top !== window;
const status = document.querySelector('#status'), content = document.querySelector('#content'), site = document.querySelector('#site');
const stateBlock = document.querySelector('#state'), stateIcon = document.querySelector('#state-icon'), secure = document.querySelector('#secure');
const opened = performance.now();
// Clickjacking: an action needs the menu fully visible for VISIBLE_MS without a break, and its rows unchanged for SETTLE_MS.
const VISIBLE_MS = 300, SETTLE_MS = 300;
let visibleSince = null, renderedAt = opened, busy = false, current = true, loading = false, last = '', kind = 'login', failure = null;
const visibilityV2 = 'isVisible' in IntersectionObserverEntry.prototype;
const observer = new IntersectionObserver(entries => {
  const entry = entries.at(-1);
  // Sub-pixel frame offsets clip a fraction of a pixel, so allow one pixel rather than an exact ratio of 1.
  const box = entry.boundingClientRect, shown = entry.intersectionRect;
  const visible = entry.isIntersecting && shown.width >= box.width - 1 && shown.height >= box.height - 1 && (!visibilityV2 || entry.isVisible === true);
  if (!visible) visibleSince = null;
  else if (visibleSince === null) visibleSince = performance.now();
  if (visible) void refresh();
}, { threshold: [0.95, 1], ...(visibilityV2 ? { trackVisibility: true, delay: 100 } : {}) });
observer.observe(document.querySelector('#viewport'));
const allowed = event => {
  const now = performance.now();
  return embedded && current && event.isTrusted && !busy && document.visibilityState === 'visible' && visibleSince !== null
    && now - visibleSince >= VISIBLE_MS && now - opened >= SETTLE_MS && now - renderedAt >= SETTLE_MS;
};
// Nothing is ever posted to the embedding page: size is fixed and closing goes through the background.
const close = refocus => { if (embedded && current && token) chrome.runtime.sendMessage({ type: 'inlineMenu', token, action: 'close', refocus }).catch(() => {}); };
async function send(action, fields = {}) {
  if (!embedded || !current || !token) return { ok: false, error: 'target-required' };
  const reply = await chrome.runtime.sendMessage({ type: 'inlineMenu', token, action, ...fields });
  if (reply.error === 'target-required' || reply.error === 'bad-origin') current = false;
  return reply;
}
const GLYPHS = { locked: 'lock', empty: 'key', 'app-unavailable': 'power', unpaired: 'link', pairing: 'link' };
function showState(state, text) {
  content.replaceChildren(); stateBlock.hidden = false; status.textContent = text;
  stateIcon.className = ['loading', 'confirm'].includes(state) ? 'kf-waiting' : `kf-icon kf-state-icon glyph-${GLYPHS[state] || 'alert'}`;
}
function primary(label, action, fields = {}) {
  const node = document.createElement('button'); node.type = 'button'; node.className = 'kf-primary'; node.textContent = label;
  node.addEventListener('click', event => void act(event, action, fields)); return node;
}
async function act(event, action, fields = {}) {
  if (!allowed(event)) return;
  if (action === 'state') { failure = null; last = ''; void refresh(); return; }
  busy = true;
  if (action === 'fill') showState('confirm', message('confirm'));
  try {
    const reply = await send(action, fields);
    if (reply.ok === false) failure = reply.error;
  } catch { failure = 'unavailable'; }
  finally { busy = false; last = ''; void refresh(); }
}
// Firefox has no visibility tracking, so an invisible overlay cannot be ruled out: the first click arms the row and the
// fill needs a second click on a button whose position the page cannot predict.
function arm(event, row, fields) {
  if (!allowed(event)) return;
  for (const other of content.querySelectorAll('.kf-confirm')) other.remove();
  for (const item of content.querySelectorAll('.kf-row')) item.dataset.selected = String(item === row);
  const strip = document.createElement('div'); strip.className = 'kf-confirm';
  const confirm = primary(message('confirmFill'), 'fill', fields);
  confirm.style.marginInlineStart = `calc((100% - 76px) * ${crypto.getRandomValues(new Uint16Array(1))[0] / 65535})`;
  strip.append(confirm); row.append(strip); renderedAt = performance.now(); confirm.focus();
}
function fillButton(node, row, fields) {
  node.addEventListener('click', event => visibilityV2 ? void act(event, 'fill', fields) : arm(event, row, fields));
}
function render(reply) {
  renderedAt = performance.now();
  if (reply.origin) { const url = new URL(reply.origin); site.textContent = url.host; site.title = url.host; secure.hidden = url.protocol !== 'https:'; }
  if (reply.kind) kind = reply.kind;
  if (failure) { showState('error', reason(failure)); content.append(primary(message('tryAgain'), 'state')); return; }
  // The app answers matches with `locked` when no database is unlocked.
  if (reply.ok === false && reply.error === 'locked') { showState('locked', message('locked')); content.append(primary(message('unlock'), 'unlock')); return; }
  if (reply.ok === false) { showState('error', reason(reply.error)); content.append(primary(message('tryAgain'), 'state')); return; }
  if (reply.state && reply.state !== 'ready') {
    showState(reply.state, message({ 'host-missing': 'hostMissing', 'app-unavailable': 'appUnavailable', unpaired: 'notPaired', pairing: 'pairBusy', error: 'unavailable' }[reply.state] || 'loading'));
    if (reply.state === 'app-unavailable') content.append(primary(message('openApp'), 'launchApp'));
    if (reply.state === 'unpaired') content.append(primary(message('pair'), 'pair'));
    if (reply.state === 'error') content.append(primary(message('tryAgain'), 'state'));
    return;
  }
  if (!Array.isArray(reply.entries)) { showState('error', reason('unavailable')); return; }
  if (!reply.entries.length) {
    if (reply.locked) { showState('locked', message('locked')); content.append(primary(message('unlock'), 'unlock')); }
    else { showState('empty', message('noLogins', new URL(reply.origin).host)); content.append(primary(message('openApp'), 'launchApp')); }
    return;
  }
  content.replaceChildren(); stateBlock.hidden = true; status.textContent = '';
  renderGroups(content, reply.entries, entry => {
    const fields = { entry: entry.entry, db: entry.db };
    const { row, login, code, reveal } = loginRow(entry, { codeOnly: kind === 'code' });
    fillButton(login, row, fields);
    if (code) fillButton(code, row, { ...fields, totp: true });
    reveal.addEventListener('click', event => void act(event, 'reveal', fields));
    return row;
  });
  if (reply.locked) { const unlock = primary(message('unlock'), 'unlock'); unlock.className = 'kf-secondary'; content.append(unlock); }
}
async function refresh() {
  if (!embedded || !current || busy || loading || visibleSince === null || document.visibilityState !== 'visible') return;
  loading = true;
  try {
    const reply = await send('state');
    delete reply.id;
    const key = JSON.stringify([reply, failure]);
    if (current && !busy && key !== last) { last = key; render(reply); }
    if (!current) { showState('error', reason('target-required')); }
  } catch { showState('error', reason('unavailable')); }
  finally { loading = false; }
}
document.addEventListener('keydown', event => {
  if (!event.isTrusted) return;
  if (event.key === 'Escape') { close(true); return; }
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  const rows = [...content.querySelectorAll('.kf-login')];
  if (!rows.length) return;
  event.preventDefault();
  const index = rows.indexOf(document.activeElement), step = event.key === 'ArrowDown' ? 1 : -1;
  rows[index < 0 ? (step > 0 ? 0 : rows.length - 1) : (index + step + rows.length) % rows.length].focus();
});
window.addEventListener('focus', () => void refresh());
document.addEventListener('visibilitychange', () => void refresh());
if (embedded && token) { showState('loading', message('loading')); void refresh(); setInterval(() => void refresh(), 1000); }
else { current = false; showState('error', reason('target-required')); }
