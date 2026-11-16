// Self-contained: executeScript serializes this function into the isolated world.
export function fillDocument(expectedOrigin, credential, codeOnly = false) {
  const result = { username: false, password: false, totp: false };
  if (location.origin !== expectedOrigin || globalThis.origin !== expectedOrigin) return result;
  const visible = input => {
    if (input.disabled || input.matches?.(':disabled') || input.readOnly || input.hidden || !['text', 'email', 'tel', 'password', 'number', 'search', 'url', ''].includes(input.type)) return false;
    for (let node = input; node; node = node.parentElement) {
      if (getComputedStyle(node).opacity === '0') return false;
    }
    const style = getComputedStyle(input), box = input.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse' && Number(style.opacity) !== 0 && input.getClientRects().length > 0 && box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
  };
  const fields = [...document.querySelectorAll('input')].filter(visible);
  const focused = fields.includes(document.activeElement) ? document.activeElement : null;
  const hint = (input, token) => (input.autocomplete || '').toLowerCase().split(/\s+/).includes(token);
  const text = input => ['text', 'email', 'tel', ''].includes(input.type);
  const candidates = focused ? fields.filter(input => input.form === focused.form) : fields;
  const password = (focused?.type === 'password' ? focused : null) || candidates.find(input => hint(input, 'current-password')) || candidates.find(input => input.type === 'password');
  const sameForm = password ? fields.filter(input => input.form === password.form) : candidates;
  const before = password ? sameForm.slice(0, sameForm.indexOf(password)).filter(input => text(input) && !hint(input, 'one-time-code')) : [];
  const username = (focused && text(focused) && !hint(focused, 'one-time-code') ? focused : null) || sameForm.find(input => hint(input, 'username') && text(input)) || before.at(-1);
  const code = (focused && hint(focused, 'one-time-code') ? focused : null) || candidates.find(input => hint(input, 'one-time-code')) || focused;
  const set = (input, value) => {
    if (!input || typeof value !== 'string') return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter) return false;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };
  if (codeOnly) result.totp = set(code, credential.totp);
  else {
    result.username = set(username, credential.username);
    result.password = set(password, credential.password);
  }
  return result;
}
export async function injectCredential(api, target, credential, codeOnly = false) {
  const destination = target.documentId ? { tabId: target.tabId, documentIds: [target.documentId] } : { tabId: target.tabId, frameIds: [target.frameId] };
  const results = await api.scripting.executeScript({ target: destination, world: 'ISOLATED', func: fillDocument, args: [target.origin, codeOnly ? { totp: credential.totp } : { username: credential.username, password: credential.password }, codeOnly] });
  const filled = results.length === 1 && results[0].frameId === target.frameId && !results[0].error && results[0].result;
  if (!filled || !(filled.username || filled.password || filled.totp)) throw new Error('no-fields');
}
