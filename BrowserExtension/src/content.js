(() => {
'use strict';
// BEGIN shared fillDocument
function fillDocument(expectedOrigin, credential, codeOnly = false, expectedToken, mode, expectedFieldKind, candidate) {
  const result = { username: false, password: false, totp: false };
  if (expectedOrigin !== undefined && (location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin)) return result;
  const pinKey = '__keeforgeDocumentPin';
  const probing = expectedOrigin === undefined;
  if (probing) {
    if (!['fields', 'visible', 'kind', 'forced', 'submitted'].includes(mode)) globalThis[pinKey] = [...crypto.getRandomValues(new Uint8Array(32))].map(n => n.toString(16).padStart(2, '0')).join('');
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
  const visible = (input, allowReadOnly = false) => {
    if (!(input instanceof HTMLInputElement) || !input.isConnected || input.ownerDocument !== document || input.disabled || input.matches(':disabled') || (input.readOnly && !allowReadOnly) || input.hidden) return false;
    let box = input.getBoundingClientRect();
    let left = Math.max(0, box.left), top = Math.max(0, box.top), right = Math.min(innerWidth, box.right), bottom = Math.min(innerHeight, box.bottom);
    if (!input.getClientRects().length || box.width <= 0 || box.height <= 0) return false;
    for (let node = input; node; node = parent(node)) {
      const style = getComputedStyle(node);
      if (prop(node, 'hidden') || prop(node, 'inert') || (prop(node, 'localName') === 'details' && !node.open) || style.display === 'none' || ['hidden', 'collapse'].includes(style.visibility) || style.contentVisibility === 'hidden' || Number(style.opacity) === 0) return false;
      // display: contents generates no box: it has no size and neither clips nor paints its descendants.
      if (style.display === 'contents') continue;
      // Reject even partial clips/masks rather than guessing at their painted geometry.
      if ([style.clipPath, style.clip, style.maskImage, style.webkitMaskImage].some(value => value && !['none', 'auto'].includes(value))) return false;
      if (node !== input && !scrollsViewport(node)) {
        box = call(node, 'getBoundingClientRect');
        // An empty box hides nothing by itself (positioned children paint outside it); overflow and paint containment clip.
        const contained = /\b(paint|strict|content)\b/.test(style.contain || '');
        const clipsX = contained || ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowX || style.overflow);
        const clipsY = contained || ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowY || style.overflow);
        if (clipsX || clipsY) {
          const clipLeft = box.left + prop(node, 'clientLeft'), clipTop = box.top + prop(node, 'clientTop');
          if (clipsX) { left = Math.max(left, clipLeft); right = Math.min(right, clipLeft + prop(node, 'clientWidth')); }
          if (clipsY) { top = Math.max(top, clipTop); bottom = Math.min(bottom, clipTop + prop(node, 'clientHeight')); }
        }
      }
    }
    return right > left && bottom > top;
  };
  if (mode === 'visible') return visible(candidate, candidate?.type === 'password');
  // A field the user right-clicked and named: only its own state counts, not the ancestor walk, because detection missed it.
  const forcedTypes = { username: ['text', 'email', 'tel', ''], password: ['password'], code: ['text', 'tel', 'number', ''] };
  const usable = (input, kind) => {
    if (!(input instanceof HTMLInputElement) || !forcedTypes[kind]?.includes(input.type) || !input.isConnected || input.ownerDocument !== document || input.disabled || input.matches(':disabled') || (input.readOnly && kind !== 'password')) return false;
    const style = getComputedStyle(input);
    return style.visibility === 'visible' && Number(style.opacity) > 0 && [...input.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight);
  };
  if (mode === 'forced') {
    if (probing) return usable(candidate, expectedFieldKind);
    const field = globalThis.__keeforgeInlineField, value = credential?.[{ username: 'username', password: 'password', code: 'totp' }[expectedFieldKind]];
    if (!usable(field, expectedFieldKind) || typeof value !== 'string') return result;
    if (field.readOnly) call(field, 'focus');
    if (field.readOnly || !usable(field, expectedFieldKind) || globalThis[pinKey] !== expectedToken || location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin) return result;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter) return result;
    setter.call(field, value);
    field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
    return { ...result, [{ username: 'username', password: 'password', code: 'totp' }[expectedFieldKind]]: true };
  }
  const allowed = input => ['text', 'email', 'tel', 'password', 'number', 'search', 'url', ''].includes(input.type);
  // Cap the inputs examined, not the elements visited, so large pages still get their login fields.
  const inputs = [], shadowGetter = member('shadowRoot')?.get;
  const collect = root => {
    for (const input of root.querySelectorAll('input')) { if (inputs.length >= 400) return; inputs.push(input); }
    for (const node of root.querySelectorAll('*')) { const shadow = shadowGetter ? shadowGetter.call(node) : node.shadowRoot; if (shadow) collect(shadow); }
  };
  collect(document);
  // Readonly-until-focus password fields count; the write focuses them first and rechecks.
  const fields = inputs.filter(input => input instanceof HTMLInputElement && allowed(input) && (visible(input) || (input.type === 'password' && input.readOnly && visible(input, true))));
  let active = document.activeElement;
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
  if (probing && !['fields', 'kind', 'submitted'].includes(mode)) return { focused: document.hasFocus() && fields.includes(active), active: fields.includes(active), touched: globalThis.__keeforgeTouched ?? 0, fillable: fields.length > 0, token: globalThis[pinKey] };
  const hint = (input, token) => (input.autocomplete || '').toLowerCase().split(/\s+/).includes(token);
  // Many sites omit the one-time-code hint; the field's name, label or placeholder still says what it is.
  const labelsOf = Object.getOwnPropertyDescriptor(globalThis.HTMLInputElement?.prototype ?? {}, 'labels')?.get;
  const describe = input => {
    const read = name => (member('getAttribute')?.value ?? input.getAttribute)?.call(input, name) ?? '';
    let labels = '';
    try { labels = [...((labelsOf ? labelsOf.call(input) : input.labels) ?? [])].map(label => label.textContent).join(' '); } catch {}
    return `${['id', 'name', 'placeholder', 'aria-label'].map(read).join(' ')} ${labels}`.toLowerCase();
  };
  const codeWords = /one[\s_-]?time|(^|[^a-z])t?otp([^a-z]|$)|2fa|two[\s_-]?factor|(^|[^a-z])mfa([^a-z]|$)|(verification|authentication|authenticator|auth|login|sign[\s_-]?in)[\s_-]?code|passcode/;
  const isCode = input => hint(input, 'one-time-code') || (['text', 'tel', 'number', ''].includes(input.type) && !['username', 'email', 'current-password', 'new-password'].some(token => hint(input, token))
    && codeWords.test(describe(input)) && !/card|cvv|cvc|csc|coupon|promo|gift|zip|postal/.test(describe(input)));
  const text = input => ['text', 'email', 'tel', ''].includes(input.type) && !hint(input, 'current-password') && !hint(input, 'new-password');
  const passwordsOf = input => fields.filter(other => other.type === 'password' && other.form === input.form);
  // A sign-up or change-password field: hinted new-password, else one of the last two password fields of a form with two or three.
  const isNew = input => {
    if (input.type !== 'password' || hint(input, 'current-password')) return false;
    if (hint(input, 'new-password')) return true;
    const passwords = passwordsOf(input);
    return passwords.length >= 2 && passwords.length <= 3 && passwords.indexOf(input) >= passwords.length - 2;
  };
  // A user-name field with no password in its form is the first step of a two-step sign-in: it gets the user name only.
  const kindOf = input => isCode(input) ? 'code' : isNew(input) ? 'new' : input.type !== 'password' && !fields.some(other => other.type === 'password' && other.form === input.form) ? 'username' : 'login';
  if (mode === 'kind') return fields.includes(candidate) ? kindOf(candidate) : null;
  const readValue = input => Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.get?.call(input) ?? '';
  // The login in the form the user just submitted: never a change of password, which would update an existing entry.
  if (mode === 'submitted') {
    const form = candidate instanceof HTMLInputElement ? candidate.form : candidate;
    const passwords = fields.filter(input => input.type === 'password' && input.form === form && !input.readOnly);
    const fresh = passwords.filter(isNew), current = passwords.filter(input => !isNew(input));
    if (!passwords.length || (fresh.length && current.length) || current.length > 1) return null;
    const chosen = fresh.length ? fresh : current, value = readValue(chosen[0]);
    if (typeof value !== 'string' || !value || [...value].length > 1024 || chosen.some(input => readValue(input) !== value)) return null;
    const names = fields.filter(input => input.form === form && text(input) && !isCode(input));
    const named = names.find(input => hint(input, 'username')) || names.filter(input => fields.indexOf(input) < fields.indexOf(chosen[0])).at(-1);
    const username = named ? String(readValue(named)).trim() : '';
    if ([...username].length > 1024) return null;
    const generated = globalThis.__keeforgeGenerated;
    return { username, password: value, generated: Array.isArray(generated) && chosen.every(input => generated.includes(input)), field: chosen[0] };
  }
  const preferred = ['inline', 'generated'].includes(mode) ? globalThis.__keeforgeInlineField : null;
  if (mode === 'inline' && (!fields.includes(preferred) || (expectedFieldKind && (kindOf(preferred) !== expectedFieldKind)))) return result;
  if (mode === 'generated' && (!fields.includes(preferred) || kindOf(preferred) !== 'new')) return result;
  const focused = fields.includes(preferred) ? preferred : fields.includes(active) ? active : null;
  if (mode === 'fields') {
    // Attributes, not properties: a form's named controls shadow its id/name/action.
    const getAttribute = member('getAttribute')?.value;
    const attributes = node => node ? ['id', 'name', 'class', 'action'].map(name => (getAttribute ?? node.getAttribute)?.call(node, name) ?? '').join(' ') : '';
    const closest = (node, selector) => (member('closest')?.value ?? node.closest)?.call(node, selector);
    const words = input => `${attributes(input)} ${input.autocomplete || ''}`.toLowerCase();
    const firstStep = input => text(input) && !isCode(input) && (input.type === 'email' || /user|login|e-?mail|account|identifier/.test(words(input)))
      && !/search|query|newsletter|subscri|coupon|promo/.test(`${words(input)} ${attributes(input.form).toLowerCase()}`) && !closest(input, '[role=search], search')
      && !fields.some(other => other !== input && other.form === input.form && (other.type === 'password' || (text(other) && !isCode(other))));
    const selected = new Set(fields.filter(input => input.type === 'password' || (text(input) && hint(input, 'username')) || (['text', 'tel', 'number', ''].includes(input.type) && isCode(input)) || firstStep(input)));
    for (const password of fields.filter(input => input.type === 'password')) {
      const before = fields.slice(0, fields.indexOf(password)).filter(input => input.form === password.form && text(input) && !isCode(input));
      const username = before.find(input => hint(input, 'username')) || before.at(-1);
      if (username) selected.add(username);
    }
    return fields.filter(input => selected.has(input)).slice(0, 20);
  }
  const candidates = focused ? fields.filter(input => input.form === focused.form) : fields;
  const password = (focused?.type === 'password' ? focused : null) || candidates.find(input => input.type === 'password' && hint(input, 'current-password')) || candidates.find(input => input.type === 'password');
  const sameForm = password ? fields.filter(input => input.form === password.form) : candidates;
  const before = password ? sameForm.slice(0, sameForm.indexOf(password)).filter(input => text(input) && !isCode(input)) : [];
  const username = (focused && text(focused) && !isCode(focused) ? focused : null) || sameForm.find(input => hint(input, 'username') && text(input)) || before.at(-1);
  const codes = candidates.filter(input => ['text', 'tel', 'number', ''].includes(input.type));
  const code = (focused && codes.includes(focused) && isCode(focused) ? focused : null) || codes.find(input => isCode(input)) || (codes.includes(focused) ? focused : null);
  let stopped = false;
  const set = (input, value, types) => {
    if (stopped || !input || typeof value !== 'string') return false;
    if (types.includes('password') && input.type === 'password' && input.readOnly) call(input, 'focus');
    if (!types.includes(input.type) || !visible(input) || globalThis[pinKey] !== expectedToken || location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin) { stopped = true; return false; }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter) return false;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };
  if (mode === 'generated') {
    // The new-password field and its confirmation, never a current password.
    const fresh = passwordsOf(preferred).filter(isNew), targets = fresh.length <= 2 ? fresh : [preferred];
    const filled = targets.filter(input => set(input, credential.password, ['password']));
    if (stopped || !filled.includes(preferred)) return { username: false, password: false, totp: false };
    globalThis.__keeforgeGenerated = filled;
    return { ...result, password: true };
  }
  if (codeOnly) result.totp = set(code, credential.totp, ['text', 'tel', 'number', '']);
  else {
    result.username = set(username, credential.username, ['text', 'email', 'tel', '']);
    result.password = set(password, credential.password, ['password']);
  }
  return stopped ? { username: false, password: false, totp: false } : result;
}
// END shared fillDocument
// The path of images/key.svg (the Node tests keep them equal); a page-visible extension image URL would expose the extension.
const KEY_PATH = 'M8 .75a4 4 0 1 1 0 8a4 4 0 1 1 0-8zM8 3a1.75 1.75 0 1 0 0 3.5a1.75 1.75 0 1 0 0-3.5zM6.9 8h2.2v7.25H6.9zM9.1 10.75h2.65v1.6H9.1zM9.1 13.65h2.15v1.6H9.1z';
// Sandboxed frames have an opaque origin and can never be filled.
if (globalThis.origin === 'null') return;
// A fixed-size menu: its size must not depend on the rows, which the page could measure by hit-testing.
const MENU = { width: 320, height: 264, minWidth: 240, minHeight: 180, gap: 6, margin: 8 };
const HOST_STYLE = 'all:initial!important;position:fixed!important;top:0!important;left:0!important;width:0!important;height:0!important;overflow:visible!important;pointer-events:none!important;z-index:2147483647!important';
const inlineURL = chrome.runtime.getURL('inline.html');
const inputs = document.getElementsByTagName('input');
let host = null, shadow = null, hostStyle = '', observer = null, gate = null, active = false;
// The last field the user right-clicked, and where: the browser's KeeForge menu item acts on it.
let contextTarget = null, contextPoint = null;
let buttons = new Map(), menu = null, scheduled = false, burst = 0, lastScan = -Infinity, pendingScan = 0, throttle = 0, fields = [], generation = 0, stopped = false;
// After an extension update or removal this copy is orphaned; remove its UI instead of leaving dead buttons.
const alive = () => { try { return Boolean(chrome.runtime?.id); } catch { return false; } };
function stop() {
  stopped = true; observer?.disconnect(); gate?.disconnect(); clearTimeout(pendingScan); clearTimeout(throttle); host?.remove(); buttons.clear(); menu = null;
  if (submitted) { clearInterval(submitted.timer); submitted = null; }
}
function message(request) {
  if (!alive()) { stop(); return Promise.reject(new Error('orphaned')); }
  return chrome.runtime.sendMessage(request);
}
globalThis.__keeforgePrepareInline = forced => {
  const field = globalThis.__keeforgeInlineField;
  if (forced) return { ...fillDocument(), kind: forced, usable: fillDocument(undefined, undefined, false, undefined, 'forced', forced, field) };
  const kind = fillDocument(undefined, undefined, false, undefined, 'kind', undefined, field);
  if (!kind || !fillDocument(undefined, undefined, false, undefined, 'fields').includes(field)) return null;
  return { ...fillDocument(), kind };
};
const flatParent = node => node.assignedSlot || node.parentElement || node.getRootNode?.().host || null;
const inside = (ancestor, node) => { for (; node; node = flatParent(node)) if (node === ancestor) return true; return false; };
const box = node => { const r = node.getBoundingClientRect(); return { left: r.left, top: r.top, width: r.width, height: r.height }; };
const moved = (a, b) => ['left', 'top', 'width', 'height'].some(key => Math.abs(a[key] - b[key]) > 1);
// The menu and buttons must sit in the field's top layer: a modal dialog makes everything outside it inert.
function layerFor(candidates) {
  const modal = document.querySelector(':modal') || document.fullscreenElement;
  if (modal) return modal;
  for (const field of candidates) for (let node = field; node; node = flatParent(node)) if (node.matches?.(':popover-open')) return node;
  return document.documentElement;
}
// Our own colours: a page can make its text transparent, which must not hide a clickable button.
function tone(field) {
  for (let node = field; node; node = flatParent(node)) {
    const [r, g, b, a = 1] = (getComputedStyle(node).backgroundColor.match(/[\d.]+/g) || []).map(Number);
    if (a >= 0.5 && Number.isFinite(b)) return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128 ? 'dark' : 'light';
  }
  return globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches && getComputedStyle(document.documentElement).colorScheme.includes('dark') ? 'dark' : 'light';
}
function close(notify = true, refocus = false) {
  ++generation;
  const previous = menu; menu = null;
  if (!previous) return;
  previous.frame.remove(); if (previous.field) buttons.get(previous.field)?.setAttribute('aria-expanded', 'false');
  if (refocus && previous.field?.isConnected) previous.field.focus({ preventScroll: true });
  if (notify) message({ type: 'closeInlineMenu', token: previous.token }).catch(() => {});
}
// Anything that moves the menu or its field after opening could slide a row under the cursor: close instead.
function check() {
  if (!menu) return;
  let replaced = false;
  if (menu.loads) { try { const doc = menu.frame.contentDocument; replaced = !!doc && doc.URL.split('#')[0] !== inlineURL; } catch {} }
  const fieldGone = menu.forced ? menu.usable && !fillDocument(undefined, undefined, false, undefined, 'forced', menu.forced, menu.field) : !fillDocument(undefined, undefined, false, undefined, 'visible', undefined, menu.field);
  if (replaced || location.href !== menu.href || innerWidth !== menu.viewport[0] || innerHeight !== menu.viewport[1] || host.style.cssText !== hostStyle || !menu.frame.isConnected
    || fieldGone || (menu.field && moved(box(menu.field), menu.fieldBox)) || moved(box(menu.frame), menu.frameBox)) close();
}
function watch() { if (!menu || stopped) return; check(); if (menu) requestAnimationFrame(watch); }
async function open(event, field) {
  if (!event.isTrusted || stopped) return;
  event.preventDefault();
  const wasOpen = menu?.field === field;
  close();
  if (wasOpen) return;
  field.focus({ preventScroll: true }); globalThis.__keeforgeInlineField = field;
  await show(field);
}
// From the browser's context menu: the field may be one discovery rejected; without a usable one the menu says why.
async function openForced(kind) {
  if (stopped || !contextPoint) return;
  close();
  const field = contextTarget?.isConnected ? contextTarget : null;
  const usable = !!field && fillDocument(undefined, undefined, false, undefined, 'forced', kind, field);
  if (usable) field.focus({ preventScroll: true });
  globalThis.__keeforgeInlineField = usable ? field : null;
  activate();
  const point = contextPoint;
  await show(usable ? field : null, kind, usable, point);
}
async function show(field, forced, usable, point) {
  const current = generation;
  try {
    const reply = await message({ type: 'openInlineMenu', ...(forced ? { forced } : {}) });
    if (typeof reply?.token !== 'string' || stopped || !shadow) return;
    if (current !== generation) { message({ type: 'closeInlineMenu', token: reply.token }).catch(() => {}); return; }
    const r = field ? field.getBoundingClientRect() : { left: point.x, right: point.x, top: point.y, bottom: point.y }, width = Math.min(MENU.width, innerWidth - 2 * MENU.margin), height = Math.min(MENU.height, innerHeight - 2 * MENU.margin);
    const below = innerHeight - r.bottom - MENU.gap - MENU.margin, above = r.top - MENU.gap - MENU.margin;
    const top = below >= height ? r.bottom + MENU.gap : above >= height ? r.top - MENU.gap - height : Math.max(MENU.margin, innerHeight - MENU.margin - height);
    const rtl = field ? getComputedStyle(field).direction === 'rtl' : document.dir === 'rtl';
    const left = Math.max(MENU.margin, Math.min(rtl ? r.right - width : r.left, innerWidth - width - MENU.margin));
    const frame = document.createElement('iframe');
    frame.title = chrome.i18n.getMessage('inlineFrameTitle');
    frame.src = inlineURL + '#' + reply.token;
    Object.assign(frame.style, { width: width + 'px', height: height + 'px', left: left + 'px', top: top + 'px' });
    menu = { field, frame, token: reply.token, loads: 0, href: location.href, viewport: [innerWidth, innerHeight], ...(forced ? { forced, usable } : {}) };
    shadow.append(frame);
    menu.fieldBox = field && box(field); menu.frameBox = box(frame);
    if (field) buttons.get(field)?.setAttribute('aria-expanded', 'true');
    // The frame loads once; a second load means something navigated it.
    frame.addEventListener('load', () => { if (menu?.frame !== frame) return; if (++menu.loads > 1) close(); else frame.focus(); });
    watch();
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
function createHost() {
  host = document.createElement('div');
  // Zero-sized: a viewport-wide overlay would count as occluding every child frame's menu for visibility tracking.
  host.style.cssText = HOST_STYLE; hostStyle = host.style.cssText;
  shadow = host.attachShadow({ mode: 'closed' });
  const style = document.createElement('style');
  // Colours are theme.css's muted tokens; the menu page draws its own border and background.
  style.textContent = `button{all:initial;box-sizing:border-box;position:fixed;display:grid;place-items:center;pointer-events:auto;cursor:pointer;border-radius:5px;color:#6b6b70;background:transparent;transition:background-color .12s}
button[data-tone=dark]{color:#a1a1a7}
button:hover,button[aria-expanded=true]{background:color-mix(in srgb,currentColor 16%,transparent)}
button:focus-visible{outline:2px solid #3070cc;outline-offset:1px}
button svg{width:16px;height:16px;display:block;pointer-events:none;fill:currentColor}
iframe{position:fixed;z-index:1;pointer-events:auto;border:0;border-radius:10px;background:transparent;color-scheme:light dark;box-shadow:0 10px 28px rgb(0 0 0/.18),0 2px 6px rgb(0 0 0/.1)}`;
  shadow.append(style);
}
function scan() {
  lastScan = performance.now();
  watchRoots(observer, OBSERVED);
  const found = fillDocument(undefined, undefined, false, undefined, 'fields');
  const layer = layerFor(found);
  fields = layer === document.documentElement || layer.matches(':popover-open') ? found : found.filter(field => inside(layer, field));
  if (host.parentNode !== layer) { close(); layer.append(host); }
  for (const [field, button] of buttons) if (!fields.includes(field)) { button.remove(); buttons.delete(field); }
  for (const field of fields) {
    let button = buttons.get(field);
    if (!button) {
      button = document.createElement('button'); button.type = 'button';
      const label = chrome.i18n.getMessage('inlineMenu');
      button.setAttribute('aria-label', label); button.title = label; button.setAttribute('aria-expanded', 'false'); button.setAttribute('aria-keyshortcuts', 'Alt+ArrowDown');
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'), path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      svg.setAttribute('viewBox', '0 0 16 16'); svg.setAttribute('aria-hidden', 'true'); path.setAttribute('d', KEY_PATH); svg.append(path); button.append(svg);
      button.addEventListener('click', event => void open(event, field)); shadow.append(button); buttons.set(field, button);
    }
    button.dataset.tone = tone(field);
  }
}
function update() {
  scheduled = false;
  if (stopped || !active) return;
  if (!alive()) { stop(); return; }
  if (host.style.cssText !== hostStyle) { close(); host.style.cssText = HOST_STYLE; hostStyle = host.style.cssText; }
  // Discovery runs at most twice a second; positions follow every frame of a burst.
  const since = performance.now() - lastScan;
  if (since >= 500 || !host.isConnected) scan();
  else if (!pendingScan) pendingScan = setTimeout(() => { pendingScan = 0; schedule(); }, 500 - since);
  // A frame too small for the menu gets no buttons; the toolbar popup still works there.
  const small = innerWidth < MENU.minWidth + 2 * MENU.margin || innerHeight < MENU.minHeight + 2 * MENU.margin;
  for (const [field, button] of buttons) {
    const r = field.getBoundingClientRect(), rtl = getComputedStyle(field).direction === 'rtl';
    const size = Math.max(16, Math.min(20, r.height - 4));
    const left = trailingEdge(field, r, rtl, size);
    const hidden = small || !fillDocument(undefined, undefined, false, undefined, 'visible', undefined, field) || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth || left < r.left || left + size > r.right;
    Object.assign(button.style, { left: left + 'px', top: (r.top + (r.height - size) / 2) + 'px', width: size + 'px', height: size + 'px', display: hidden ? 'none' : 'grid' });
  }
  check();
  if (burst > 0) { --burst; schedule(); }
}
function schedule() { if (!scheduled && !stopped && active) { scheduled = true; requestAnimationFrame(update); } }
// Events start a short burst of per-frame positioning so transitions and smooth scrolling are followed.
function nudge() { burst = 30; schedule(); }
const relevant = node => node !== host && [...buttons.keys()].some(field => node === field || node.contains?.(field));
// Style churn elsewhere (spinners, script animations) gets at most four single updates a second, never a frame loop.
function later() { if (!throttle) throttle = setTimeout(() => { throttle = 0; schedule(); }, 250); }
function mutated(records) {
  if (records.some(record => record.type === 'childList' || relevant(record.target))) nudge(); else later();
}
const OBSERVED = { subtree: true, childList: true, attributes: true, attributeFilter: ['style', 'class', 'hidden', 'type', 'autocomplete', 'readonly', 'disabled', 'inert', 'open', 'popover', 'dir', 'id', 'name'] };
const shadowOf = Object.getOwnPropertyDescriptor(Element.prototype, 'shadowRoot').get;
let watched = new WeakSet(), gateTimer = 0;
// A document observer does not see inside open shadow roots: watch each one found (at most 100) and say whether any holds an input.
function watchRoots(target, options) {
  let found = false, count = 0;
  const walk = root => {
    for (const node of root.querySelectorAll('*')) {
      const inner = shadowOf.call(node);
      if (!inner || ++count > 100) continue;
      if (!watched.has(inner)) { watched.add(inner); target.observe(inner, options); }
      if (inner.querySelector('input')) found = true;
      walk(inner);
    }
  };
  walk(document);
  return found;
}
// Pages with no input get no host or update loop until one appears.
function activate() {
  if (active || stopped || !document.documentElement) return;
  active = true; gate?.disconnect(); createHost();
  watched = new WeakSet();
  observer = new MutationObserver(mutated);
  observer.observe(document.documentElement, OBSERVED);
  globalThis.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', () => { lastScan = -Infinity; nudge(); });
  nudge();
}
function init() {
  if (active || stopped) return;
  if (inputs.length) { activate(); return; }
  if (!document.documentElement) return;
  const options = { childList: true, subtree: true };
  const deep = () => { if (!active && !stopped && (inputs.length || watchRoots(gate, options))) activate(); };
  if (!gate) {
    // Light-DOM inputs wake at once; the walk into shadow roots runs at most twice a second.
    gate = new MutationObserver(() => { if (inputs.length) activate(); else if (!gateTimer) gateTimer = setTimeout(() => { gateTimer = 0; deep(); }, 500); });
    gate.observe(document.documentElement, options);
  }
  deep();
}
// Registered at document_start so these run before any listener a page adds and cannot be stopped by it.
const on = (type, listener) => addEventListener(type, event => { if (!stopped) listener(event); }, true);
on('DOMContentLoaded', init); on('load', init);
// The popup's frame choice reads this: the frame the user last clicked or typed in. Script focus and synthetic events do not count.
const touch = event => { if (event.isTrusted) globalThis.__keeforgeTouched = Date.now(); };
on('pointerdown', touch); on('keydown', touch);
on('focusin', event => {
  const target = event.composedPath()[0];
  if (target instanceof HTMLInputElement) { activate(); if (!buttons.has(target)) lastScan = -Infinity; }
  nudge();
});
on('scroll', nudge); on('resize', nudge);
on('transitionrun', event => { if (relevant(event.target)) nudge(); });
on('animationstart', event => { if (relevant(event.target)) nudge(); });
on('toggle', () => { lastScan = -Infinity; nudge(); }); on('fullscreenchange', () => { lastScan = -Infinity; nudge(); });
on('contextmenu', event => {
  if (!event.isTrusted) return;
  const target = event.composedPath()[0];
  contextTarget = target instanceof HTMLInputElement ? target : null; contextPoint = { x: event.clientX, y: event.clientY };
});
const forget = () => { contextTarget = null; contextPoint = null; };
// After a trusted submit of a form with a password, the page shows whether the sign-in went through: it navigates or the
// password field goes away (success), or the field is still there after 10 s (failed or abandoned). Only then may the
// background offer the login to the app. The watch is bounded and stops at the first answer.
const OUTCOME_MS = 10000;
let submitted = null;
function outcome(succeeded) {
  const current = submitted; submitted = null;
  if (!current) return;
  clearInterval(current.timer);
  message({ type: 'loginOutcome', succeeded }).catch(() => {});
}
on('submit', event => {
  const form = event.composedPath()[0];
  if (!event.isTrusted || !(form instanceof HTMLFormElement)) return;
  const values = fillDocument(undefined, undefined, false, undefined, 'submitted', undefined, form);
  if (!values) return;
  if (submitted) { clearInterval(submitted.timer); submitted = null; }
  const { field, username, password, generated } = values, href = location.href, started = performance.now();
  submitted = { timer: setInterval(() => {
    if (location.href !== href || !fillDocument(undefined, undefined, false, undefined, 'visible', undefined, field)) outcome(true);
    else if (performance.now() - started >= OUTCOME_MS) outcome(false);
  }, 250) };
  message({ type: 'loginSubmitted', username, password, generated }).catch(() => {});
});
// Typing over a generated password makes it the user's own.
on('input', event => {
  if (event.isTrusted && globalThis.__keeforgeGenerated?.includes(event.composedPath()[0])) globalThis.__keeforgeGenerated = null;
});
on('pagehide', () => { close(); forget(); outcome(true); }); on('popstate', () => { close(); forget(); }); on('hashchange', () => { close(); forget(); });
on('keydown', event => {
  if (!event.isTrusted) return;
  if (event.key === 'Escape' && menu) { close(true, true); return; }
  // Alt+Down opens the menu from a decorated field, so the button is not reachable only at the end of the tab order.
  const field = event.composedPath()[0];
  if (event.key === 'ArrowDown' && event.altKey && !event.ctrlKey && !event.metaKey && buttons.get(field)?.style.display === 'grid') void open(event, field);
});
on('pointerdown', event => { if (event.isTrusted && menu && !event.composedPath().includes(host)) close(); });
chrome.runtime.onMessage.addListener((request, sender) => {
  if (stopped || sender?.id !== chrome.runtime.id) return;
  if (request?.type === 'closeInlineMenu' && request.token === menu?.token) close(false, request.refocus === true);
  if (request?.type === 'contextFill' && ['username', 'password', 'code'].includes(request.kind)) void openForced(request.kind);
});
if (document.readyState !== 'loading') init();
})();
