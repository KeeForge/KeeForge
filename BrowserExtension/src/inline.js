import { message, reason, localizePage } from './i18n.js';
import { groupsFor } from './popup-state.js';
localizePage();
const token = location.hash.slice(1), embedded = window.top !== window;
const status = document.querySelector('#status'), content = document.querySelector('#content'), site = document.querySelector('#site'), sizer = document.querySelector('#sizer');
const opened = performance.now();
// Clickjacking: an action needs the menu fully visible for VISIBLE_MS without a break, and its rows unchanged for SETTLE_MS.
const VISIBLE_MS = 300, SETTLE_MS = 300;
let visibleSince = null, renderedAt = opened, busy = false, current = true, loading = false, last = '', kind = 'login';
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
const close = (refocus = false) => parent.postMessage({ type: 'inlineClose', refocus }, '*');
async function send(action, fields = {}) {
  if (!embedded || !current || !token) return { ok: false, error: 'target-required' };
  const reply = await chrome.runtime.sendMessage({ type: 'inlineMenu', token, action, ...fields });
  if (reply.error === 'target-required' || reply.error === 'bad-origin') {
    current = false; content.replaceChildren(); close();
  }
  return reply;
}
function resize() {
  const height = Math.ceil(sizer?.getBoundingClientRect().height ?? 0);
  parent.postMessage({ type: 'inlineSize', height: Math.min(420, Math.max(80, height)) }, '*');
}
const ICONS = { code: ['M8 5.5v3l2 1.2', 'M6.5 1.5h3', 'M13.5 8.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0'], reveal: ['M9 3h4v4', 'M13 3 7.5 8.5', 'M11 9.5V13H3V5h3.5'] };
function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  for (const [key, value] of Object.entries({ width: 16, height: 16, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) svg.setAttribute(key, value);
  for (const d of ICONS[name]) { const path = document.createElementNS('http://www.w3.org/2000/svg', 'path'); path.setAttribute('d', d); svg.append(path); }
  return svg;
}
function notice(text, className = '') { status.textContent = text; status.className = className; }
function button(label, action, fields = {}, className = 'primary') {
  const node = document.createElement('button'); node.type = 'button'; node.className = className;
  if (label) node.textContent = label;
  node.addEventListener('click', async event => {
    if (!allowed(event)) return;
    busy = true;
    if (action === 'fill') { notice(message('confirm'), 'confirm'); content.classList.add('busy'); for (const button of content.querySelectorAll('button')) button.disabled = true; resize(); }
    try {
      const reply = await send(action, fields);
      if (reply.ok === false) { notice(reason(reply.error), 'error'); last = ''; }
      else if (action === 'fill') close();
    } catch { notice(reason('unavailable'), 'error'); last = ''; }
    finally { busy = false; content.classList.remove('busy'); for (const button of content.querySelectorAll('button')) button.disabled = false; void refresh(); }
  });
  return node;
}
function iconButton(name, label, action, fields) {
  const node = button('', action, fields, 'icon');
  node.setAttribute('aria-label', label); node.title = label; node.append(icon(name));
  return node;
}
function render(reply) {
  content.replaceChildren(); notice('');
  renderedAt = performance.now();
  site.textContent = reply.origin ? new URL(reply.origin).host : '';
  if (reply.kind) kind = reply.kind;
  if (reply.ok === false) { notice(reason(reply.error), 'error'); content.append(button(message('tryAgain'), 'state')); }
  else if (reply.state && reply.state !== 'ready') {
    notice(message({ 'host-missing': 'hostMissing', 'app-unavailable': 'appUnavailable', unpaired: 'notPaired', pairing: 'pairBusy', error: 'unavailable' }[reply.state] || 'loading'));
    if (reply.state === 'app-unavailable') content.append(button(message('openApp'), 'launchApp'));
    if (reply.state === 'unpaired') content.append(button(message('pair'), 'pair'));
  } else if (Array.isArray(reply.entries)) {
    if (!reply.entries.length) notice(reply.locked ? message('locked') : message('noLogins', new URL(reply.origin).host), 'empty');
    let other = false;
    for (const group of groupsFor(reply.entries)) {
      if (!group.exact && !other) { const h = document.createElement('h2'); h.textContent = message('otherLogins'); content.append(h); other = true; }
      if (group.name) { const h = document.createElement('h3'); h.textContent = group.name; content.append(h); }
      for (const entry of group.entries) {
        const fields = { entry: entry.entry, db: entry.db };
        const row = document.createElement('div'); row.className = 'row';
        const login = button('', 'fill', fields, 'login');
        login.setAttribute('aria-label', kind === 'code' ? message('fillCodeFor', [entry.title]) : message('fillLogin', [entry.title, entry.username]));
        const title = document.createElement('span'); title.className = 'title'; title.textContent = entry.title;
        const username = document.createElement('span'); username.className = 'username'; username.textContent = entry.username;
        login.append(title, username); row.append(login);
        if (kind !== 'code' && entry.hasTotp) row.append(iconButton('code', message('fillCodeFor', [entry.title]), 'fill', { ...fields, totp: true }));
        row.append(iconButton('reveal', message('reveal'), 'reveal', fields)); content.append(row);
      }
    }
    if (reply.locked) content.append(button(message('unlock'), 'unlock', {}, reply.entries.length ? 'secondary' : 'primary'));
  }
  resize();
}
async function refresh() {
  if (!embedded || !current || busy || loading || visibleSince === null || document.visibilityState !== 'visible') return;
  loading = true;
  try {
    const reply = await send('state');
    delete reply.id;
    if (current && !busy && JSON.stringify(reply) !== last) { last = JSON.stringify(reply); render(reply); }
  } catch { notice(reason('unavailable'), 'error'); }
  finally { loading = false; }
}
document.addEventListener('keydown', event => {
  if (!event.isTrusted) return;
  if (event.key === 'Escape') { close(true); return; }
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  const rows = [...content.querySelectorAll('.login')];
  if (!rows.length) return;
  event.preventDefault();
  const index = rows.indexOf(document.activeElement), step = event.key === 'ArrowDown' ? 1 : -1;
  rows[index < 0 ? (step > 0 ? 0 : rows.length - 1) : (index + step + rows.length) % rows.length].focus();
});
window.addEventListener('focus', () => void refresh());
document.addEventListener('visibilitychange', () => void refresh());
if (embedded && token) { notice(message('loading')); void refresh(); setInterval(() => void refresh(), 1000); }
else { current = false; notice(reason('target-required'), 'error'); }
