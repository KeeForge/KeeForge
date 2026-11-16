// Self-contained: executeScript serializes this function into the isolated world.
export function fillDocument(expectedOrigin, credential, codeOnly = false, expectedToken) {
  const result = { username: false, password: false, totp: false };
  if (expectedOrigin !== undefined && (location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin)) return result;
  const pinKey = '__keeforgeDocumentPin';
  const probing = expectedOrigin === undefined;
  if (probing) globalThis[pinKey] = [...crypto.getRandomValues(new Uint8Array(32))].map(n => n.toString(16).padStart(2, '0')).join('');
  else if (!expectedToken || globalThis[pinKey] !== expectedToken) return result;
  const parent = node => node.assignedSlot || node.parentElement || node.getRootNode?.().host;
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
      if (node.hidden || node.inert || (node.localName === 'details' && !node.open) || style.display === 'none' || ['hidden', 'collapse'].includes(style.visibility) || style.contentVisibility === 'hidden' || Number(style.opacity) === 0) return false;
      // Reject even partial clips/masks rather than guessing at their painted geometry.
      if ([style.clipPath, style.clip, style.maskImage, style.webkitMaskImage].some(value => value && !['none', 'auto'].includes(value))) return false;
      if (node !== input && !scrollsViewport(node)) {
        box = node.getBoundingClientRect();
        if (box.width <= 0 || box.height <= 0) return false;
        const clipsX = ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowX || style.overflow);
        const clipsY = ['hidden', 'clip', 'scroll', 'auto'].includes(style.overflowY || style.overflow);
        if (clipsX || clipsY) {
          const clipLeft = box.left + node.clientLeft, clipTop = box.top + node.clientTop;
          if (clipsX) { left = Math.max(left, clipLeft); right = Math.min(right, clipLeft + node.clientWidth); }
          if (clipsY) { top = Math.max(top, clipTop); bottom = Math.min(bottom, clipTop + node.clientHeight); }
        }
      }
    }
    return right > left && bottom > top;
  };
  const allowed = input => ['text', 'email', 'tel', 'password', 'number', 'search', 'url', ''].includes(input.type);
  const fields = [];
  const collect = root => {
    for (const node of root.querySelectorAll('*')) {
      if (node instanceof HTMLInputElement && allowed(node) && visible(node)) fields.push(node);
      if (node.shadowRoot) collect(node.shadowRoot);
    }
  };
  collect(document);
  let active = document.activeElement;
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
  if (probing) return { focused: document.hasFocus() && fields.includes(active), fillable: fields.length > 0, token: globalThis[pinKey] };
  const focused = fields.includes(active) ? active : null;
  const hint = (input, token) => (input.autocomplete || '').toLowerCase().split(/\s+/).includes(token);
  const text = input => ['text', 'email', 'tel', ''].includes(input.type) && !hint(input, 'current-password') && !hint(input, 'new-password');
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
export async function injectCredential(api, target, credential, codeOnly = false) {
  const destination = target.documentId ? { tabId: target.tabId, documentIds: [target.documentId] } : { tabId: target.tabId, frameIds: [target.frameId] };
  const results = await api.scripting.executeScript({ target: destination, world: 'ISOLATED', func: fillDocument, args: [target.origin, codeOnly ? { totp: credential.totp } : { username: credential.username, password: credential.password }, codeOnly, target.token] });
  const filled = results.length === 1 && results[0].frameId === target.frameId && !results[0].error && results[0].result;
  if (!filled || !(filled.username || filled.password || filled.totp)) throw new Error('no-fields');
}
