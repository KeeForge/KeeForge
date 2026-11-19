(() => {
'use strict';
// BEGIN shared fillDocument
function fillDocument(expectedOrigin, credential, codeOnly = false, expectedToken, mode, expectedFieldKind, candidate) {
  const result = { username: false, password: false, totp: false };
  if (expectedOrigin !== undefined && (location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin)) return result;
  const pinKey = '__keeforgeDocumentPin';
  const probing = expectedOrigin === undefined;
  if (probing) {
    if (!['fields', 'visible'].includes(mode)) globalThis[pinKey] = [...crypto.getRandomValues(new Uint8Array(32))].map(n => n.toString(16).padStart(2, '0')).join('');
  } else if (!expectedToken || globalThis[pinKey] !== expectedToken) return result;
  // A form's named controls (e.g. <input name="hidden">) shadow its DOM members; read them from the prototypes.
  const prototypes = ['HTMLElement', 'Element', 'Node'].map(name => globalThis[name]?.prototype).filter(Boolean);
  const member = name => prototypes.map(proto => Object.getOwnPropertyDescriptor(proto, name)).find(Boolean);
  const prop = (node, name) => { const get = member(name)?.get; return get ? get.call(node) : node[name]; };
  const call = (node, name) => (member(name)?.value ?? node[name])?.call(node);
  const parent = node => prop(node, 'assignedSlot') || prop(node, 'parentElement') || call(node, 'getRootNode')?.host;
  const root = document.documentElement, body = document.body;
  // Overflow on these elements moves to the viewport, which the initial bounds already intersect.
  const scrollsViewport = node => (node === root && getComputedStyle(root).contain === 'none') || (node === body && [root, body].every(element => getComputedStyle(element).contain === 'none') && ['overflowX', 'overflowY'].every(axis => getComputedStyle(root)[axis] === 'visible'));
  const visible = input => {
    if (!(input instanceof HTMLInputElement) || !input.isConnected || input.ownerDocument !== document || input.disabled || input.matches(':disabled') || input.readOnly || input.hidden) return false;
    let box = input.getBoundingClientRect();
    let left = Math.max(0, box.left), top = Math.max(0, box.top), right = Math.min(innerWidth, box.right), bottom = Math.min(innerHeight, box.bottom);
    if (!input.getClientRects().length || box.width <= 0 || box.height <= 0) return false;
    for (let node = input; node; node = parent(node)) {
      const style = getComputedStyle(node);
      if (prop(node, 'hidden') || prop(node, 'inert') || (prop(node, 'localName') === 'details' && !node.open) || style.display === 'none' || ['hidden', 'collapse'].includes(style.visibility) || style.contentVisibility === 'hidden' || Number(style.opacity) === 0) return false;
      // Reject even partial clips/masks rather than guessing at their painted geometry.
      if ([style.clipPath, style.clip, style.maskImage, style.webkitMaskImage].some(value => value && !['none', 'auto'].includes(value))) return false;
      if (node !== input && !scrollsViewport(node)) {
        box = call(node, 'getBoundingClientRect');
        if (box.width <= 0 || box.height <= 0) return false;
        const clipsX = ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowX || style.overflow);
        const clipsY = ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowY || style.overflow);
        if (clipsX || clipsY) {
          const clipLeft = box.left + prop(node, 'clientLeft'), clipTop = box.top + prop(node, 'clientTop');
          if (clipsX) { left = Math.max(left, clipLeft); right = Math.min(right, clipLeft + prop(node, 'clientWidth')); }
          if (clipsY) { top = Math.max(top, clipTop); bottom = Math.min(bottom, clipTop + prop(node, 'clientHeight')); }
        }
      }
    }
    return right > left && bottom > top;
  };
  if (mode === 'visible') return visible(candidate);
  const allowed = input => ['text', 'email', 'tel', 'password', 'number', 'search', 'url', ''].includes(input.type);
  const fields = [];
  let visited = 0;
  const collect = root => {
    const nodes = mode === 'fields' ? { *[Symbol.iterator]() {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      let node;
      while (visited < 6000 && (node = walker.nextNode())) { ++visited; yield node; }
    } } : root.querySelectorAll('*');
    for (const node of nodes) {
      if (node instanceof HTMLInputElement && allowed(node) && visible(node)) fields.push(node);
      const shadow = prop(node, 'shadowRoot');
      if (shadow) collect(shadow);
    }
  };
  collect(document);
  let active = document.activeElement;
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
  if (probing && mode !== 'fields') return { focused: document.hasFocus() && fields.includes(active), fillable: fields.length > 0, token: globalThis[pinKey] };
  const hintKind = input => (input.autocomplete || '').toLowerCase().split(/\s+/).includes('one-time-code') ? 'code' : 'login';
  const preferred = mode === 'inline' ? globalThis.__keeforgeInlineField : null;
  if (mode === 'inline' && (!fields.includes(preferred) || (expectedFieldKind && (hintKind(preferred) !== expectedFieldKind)))) return result;
  const focused = fields.includes(preferred) ? preferred : fields.includes(active) ? active : null;
  const hint = (input, token) => (input.autocomplete || '').toLowerCase().split(/\s+/).includes(token);
  const text = input => ['text', 'email', 'tel', ''].includes(input.type) && !hint(input, 'current-password') && !hint(input, 'new-password');
  if (mode === 'fields') {
    const selected = new Set(fields.filter(input => input.type === 'password' || (text(input) && hint(input, 'username')) || (['text', 'tel', 'number', ''].includes(input.type) && hint(input, 'one-time-code'))));
    for (const password of fields.filter(input => input.type === 'password')) {
      const before = fields.slice(0, fields.indexOf(password)).filter(input => input.form === password.form && text(input) && !hint(input, 'one-time-code'));
      const username = before.find(input => hint(input, 'username')) || before.at(-1);
      if (username) selected.add(username);
    }
    return [...selected].slice(0, 20);
  }
  const candidates = focused ? fields.filter(input => input.form === focused.form) : fields;
  const password = (focused?.type === 'password' ? focused : null) || candidates.find(input => input.type === 'password' && hint(input, 'current-password')) || candidates.find(input => input.type === 'password');
  const sameForm = password ? fields.filter(input => input.form === password.form) : candidates;
  const before = password ? sameForm.slice(0, sameForm.indexOf(password)).filter(input => text(input) && !hint(input, 'one-time-code')) : [];
  const username = (focused && text(focused) && !hint(focused, 'one-time-code') ? focused : null) || sameForm.find(input => hint(input, 'username') && text(input)) || before.at(-1);
  const codes = candidates.filter(input => ['text', 'tel', 'number', ''].includes(input.type));
  const code = (focused && codes.includes(focused) && hint(focused, 'one-time-code') ? focused : null) || codes.find(input => hint(input, 'one-time-code')) || (codes.includes(focused) ? focused : null);
  let stopped = false;
  const set = (input, value, types) => {
    if (stopped || !input || typeof value !== 'string') return false;
    if (!types.includes(input.type) || !visible(input) || globalThis[pinKey] !== expectedToken || location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin) { stopped = true; return false; }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter) return false;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };
  if (codeOnly) result.totp = set(code, credential.totp, ['text', 'tel', 'number', '']);
  else {
    result.username = set(username, credential.username, ['text', 'email', 'tel', '']);
    result.password = set(password, credential.password, ['password']);
  }
  return stopped ? { username: false, password: false, totp: false } : result;
}
// END shared fillDocument
const KEY_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="11" r="3"/><path d="M7.2 8.8 13 3M11 5l2 2M9 7l1.5 1.5"/></svg>';
const host = document.createElement('div');
// Zero-sized: a viewport-wide overlay would count as occluding every child frame's menu for visibility tracking.
host.style.cssText = 'all:initial!important;position:fixed!important;top:0!important;left:0!important;width:0!important;height:0!important;overflow:visible!important;pointer-events:none!important;z-index:2147483647!important';
const shadow = host.attachShadow({ mode: 'closed' });
const style = document.createElement('style');
// The menu page follows prefers-color-scheme, so its frame border does too.
style.textContent = `button{all:initial;box-sizing:border-box;position:fixed;display:grid;place-items:center;pointer-events:auto;cursor:pointer;border-radius:5px;background:transparent;opacity:.6;transition:opacity .12s,background-color .12s}
button:hover,button[aria-expanded=true]{opacity:1;background:color-mix(in srgb,currentColor 12%,transparent)}
button:focus-visible{opacity:1;outline:2px solid color-mix(in srgb,currentColor 70%,transparent);outline-offset:1px}
button svg{width:16px;height:16px;display:block;pointer-events:none}
iframe{position:fixed;z-index:1;pointer-events:auto;border:1px solid #d0d4dc;border-radius:10px;box-shadow:0 10px 28px rgb(0 0 0/.16),0 2px 6px rgb(0 0 0/.08);background:#fff;color-scheme:light}
@media (prefers-color-scheme:dark){iframe{border-color:#464b55;background:#1f2127;color-scheme:dark;box-shadow:0 10px 28px rgb(0 0 0/.5)}}`;
shadow.append(style); document.documentElement.append(host);
let buttons = new Map(), menu = null, scheduled = false, burst = 0, lastScan = -Infinity, pendingScan = 0, fields = [], generation = 0, lastHref = location.href, stopped = false;
const extensionOrigin = chrome.runtime.getURL('').split('/').slice(0, 3).join('/');
const kind = field => field.autocomplete.toLowerCase().split(/\s+/).includes('one-time-code') ? 'code' : 'login';
// After an extension update or removal this copy is orphaned; remove its UI instead of leaving dead buttons.
const alive = () => { try { return Boolean(chrome.runtime?.id); } catch { return false; } };
function stop() {
  stopped = true; observer.disconnect(); clearInterval(timer); clearTimeout(pendingScan); host.remove(); buttons.clear(); menu = null;
}
function message(request) {
  if (!alive()) { stop(); return Promise.reject(new Error('orphaned')); }
  return chrome.runtime.sendMessage(request);
}
globalThis.__keeforgePrepareInline = () => {
  const field = globalThis.__keeforgeInlineField;
  if (!fillDocument(undefined, undefined, false, undefined, 'fields').includes(field)) return null;
  return { ...fillDocument(), kind: kind(field) };
};
function close(notify = true, refocus = false) {
  ++generation;
  const previous = menu; menu = null;
  if (!previous) return;
  previous.frame.remove(); buttons.get(previous.field)?.setAttribute('aria-expanded', 'false');
  if (refocus && previous.field.isConnected) previous.field.focus({ preventScroll: true });
  if (notify && previous.token) message({ type: 'closeInlineMenu', token: previous.token }).catch(() => {});
}
function positionMenu() {
  if (!menu) return;
  if (!fields.includes(menu.field) || !fillDocument(undefined, undefined, false, undefined, 'visible', undefined, menu.field)) { close(); return; }
  const r = menu.field.getBoundingClientRect(), width = Math.min(320, innerWidth - 16);
  const below = innerHeight - r.bottom - 12, above = r.top - 12;
  const height = Math.min(menu.height, Math.max(below, above));
  if (height < 80 || r.bottom <= 0 || r.top >= innerHeight) { close(); return; }
  const rtl = getComputedStyle(menu.field).direction === 'rtl';
  const left = Math.max(8, Math.min(rtl ? r.right - width : r.left, innerWidth - width - 8));
  Object.assign(menu.frame.style, { width: width + 'px', height: height + 'px', left: left + 'px', top: (below >= height ? r.bottom + 6 : r.top - height - 6) + 'px' });
}
async function open(event, field) {
  if (!event.isTrusted) return;
  event.preventDefault();
  const wasOpen = menu?.field === field;
  close();
  if (wasOpen) return;
  field.focus({ preventScroll: true }); globalThis.__keeforgeInlineField = field;
  const current = generation;
  try {
    const reply = await message({ type: 'openInlineMenu' });
    if (typeof reply?.token !== 'string' || current !== generation || stopped) return;
    const frame = document.createElement('iframe');
    frame.title = chrome.i18n.getMessage('inlineMenu');
    frame.src = chrome.runtime.getURL('inline.html') + '#' + reply.token;
    menu = { field, frame, token: reply.token, height: 160 }; shadow.append(frame); positionMenu();
    buttons.get(field)?.setAttribute('aria-expanded', 'true');
    frame.addEventListener('load', () => { if (menu?.frame === frame) frame.focus(); });
  } catch { close(); }
}
// Leave room for a site's own control (show-password eye, clear button) drawn over the field's trailing edge.
function trailingEdge(field, r, rtl, size) {
  const root = typeof field.getRootNode === 'function' ? field.getRootNode() : document;
  const hits = typeof root.elementsFromPoint === 'function' ? root.elementsFromPoint.bind(root) : () => [];
  const y = r.top + r.height / 2;
  let edge = rtl ? r.left + 4 : r.right - 4;
  for (let i = 0; i < 3; ++i) {
    const hit = hits(rtl ? edge + size / 2 : edge - size / 2, y).find(node => node !== host);
    if (!hit || hit === field || hit.contains(field)) break;
    const c = hit.getBoundingClientRect();
    if (c.width > r.width / 2 || c.height > r.height * 1.5) break;
    edge = rtl ? c.right + 4 : c.left - 4;
  }
  return rtl ? edge : edge - size;
}
function scan() {
  fields = fillDocument(undefined, undefined, false, undefined, 'fields'); lastScan = performance.now();
  for (const [field, button] of buttons) if (!fields.includes(field)) { button.remove(); buttons.delete(field); }
  for (const field of fields) if (!buttons.has(field)) {
    const button = document.createElement('button'); button.type = 'button';
    button.setAttribute('aria-label', chrome.i18n.getMessage('inlineMenu')); button.setAttribute('aria-expanded', 'false'); button.innerHTML = KEY_SVG;
    button.addEventListener('click', event => void open(event, field)); shadow.append(button); buttons.set(field, button);
  }
}
function update() {
  scheduled = false;
  if (stopped) return;
  if (!alive()) { stop(); return; }
  if (location.href !== lastHref) { lastHref = location.href; close(); }
  // Discovery is bounded and runs at most twice a second; positions follow every frame of a burst.
  const since = performance.now() - lastScan;
  if (since >= 500) scan();
  else if (!pendingScan) pendingScan = setTimeout(() => { pendingScan = 0; schedule(); }, 500 - since);
  for (const [field, button] of buttons) {
    const r = field.getBoundingClientRect(), fieldStyle = getComputedStyle(field), rtl = fieldStyle.direction === 'rtl';
    const size = Math.max(16, Math.min(20, r.height - 4));
    const left = trailingEdge(field, r, rtl, size);
    const hidden = !fillDocument(undefined, undefined, false, undefined, 'visible', undefined, field) || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth || left < r.left || left + size > r.right;
    Object.assign(button.style, { left: left + 'px', top: (r.top + (r.height - size) / 2) + 'px', width: size + 'px', height: size + 'px', color: fieldStyle.color, display: hidden ? 'none' : 'grid' });
  }
  positionMenu();
  if (burst > 0) { --burst; schedule(); }
}
function schedule() { if (!scheduled && !stopped) { scheduled = true; requestAnimationFrame(update); } }
// Events start a short burst of per-frame positioning so transitions and smooth scrolling are followed.
function nudge() { burst = 30; schedule(); }
const observer = new MutationObserver(nudge);
observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true });
// Polling discovers fields inside open shadow roots attached later, without patching page APIs.
const timer = setInterval(schedule, 1000);
const on = (type, listener) => addEventListener(type, event => { if (!stopped) listener(event); }, true);
on('scroll', nudge); on('resize', nudge); on('transitionrun', nudge); on('animationstart', nudge); on('focusin', nudge);
globalThis.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', nudge);
on('pagehide', () => close()); on('popstate', () => close()); on('hashchange', () => close());
on('keydown', event => { if (event.key === 'Escape' && event.isTrusted && menu) close(true, true); });
on('pointerdown', event => { if (event.isTrusted && menu && !event.composedPath().includes(host)) close(); });
chrome.runtime.onMessage.addListener(request => { if (!stopped && request?.type === 'closeInlineMenu' && request.token === menu?.token) close(false); });
on('message', event => {
  if (!menu || event.source !== menu.frame.contentWindow || event.origin !== extensionOrigin) return;
  if (event.data?.type === 'inlineSize' && Number.isFinite(event.data.height) && event.data.height >= 80 && event.data.height <= 420) { menu.height = event.data.height; positionMenu(); }
  if (event.data?.type === 'inlineClose') close(true, event.data.refocus === true);
});
schedule();
})();
