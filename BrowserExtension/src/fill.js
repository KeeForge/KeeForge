// Self-contained: executeScript serializes this function into the isolated world.
export function fillDocument(expectedOrigin, credential, codeOnly = false, expectedToken, mode, expectedFieldKind, candidate) {
  const result = { username: false, password: false, totp: false };
  if (expectedOrigin !== undefined && (location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin)) return result;
  const pinKey = '__keeforgeDocumentPin';
  const probing = expectedOrigin === undefined;
  if (probing) {
    if (!['fields', 'visible', 'kind', 'forced'].includes(mode)) globalThis[pinKey] = [...crypto.getRandomValues(new Uint8Array(32))].map(n => n.toString(16).padStart(2, '0')).join('');
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
  if (probing && !['fields', 'kind'].includes(mode)) return { focused: document.hasFocus() && fields.includes(active), active: fields.includes(active), touched: globalThis.__keeforgeTouched ?? 0, fillable: fields.length > 0, token: globalThis[pinKey] };
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
  // A user-name field with no password in its form is the first step of a two-step sign-in: it gets the user name only.
  const kindOf = input => isCode(input) ? 'code' : input.type !== 'password' && !fields.some(other => other.type === 'password' && other.form === input.form) ? 'username' : 'login';
  if (mode === 'kind') return fields.includes(candidate) ? kindOf(candidate) : null;
  const preferred = mode === 'inline' ? globalThis.__keeforgeInlineField : null;
  if (mode === 'inline' && (!fields.includes(preferred) || (expectedFieldKind && (kindOf(preferred) !== expectedFieldKind)))) return result;
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
  if (codeOnly) result.totp = set(code, credential.totp, ['text', 'tel', 'number', '']);
  else {
    result.username = set(username, credential.username, ['text', 'email', 'tel', '']);
    result.password = set(password, credential.password, ['password']);
  }
  return stopped ? { username: false, password: false, totp: false } : result;
}
export async function injectCredential(api, target, credential, codeOnly = false) {
  const destination = target.documentId ? { tabId: target.tabId, documentIds: [target.documentId] } : { tabId: target.tabId, frameIds: [target.frameId] };
  const values = codeOnly ? { totp: credential.totp } : target.kind === 'username' ? { username: credential.username } : target.kind === 'password' ? { password: credential.password } : { username: credential.username, password: credential.password };
  const results = await api.scripting.executeScript({ target: destination, world: 'ISOLATED', func: fillDocument, args: [target.origin, values, codeOnly, target.token, ...(target.forced ? ['forced', target.kind] : target.inline ? ['inline', target.kind] : [])] });
  const filled = results.length === 1 && results[0].frameId === target.frameId && !results[0].error && results[0].result;
  if (!filled || !(filled.username || filled.password || filled.totp)) throw new Error('no-fields');
}
