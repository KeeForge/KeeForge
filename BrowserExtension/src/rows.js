// Login rows shared by the popup and the inline menu; untrusted entry metadata only ever goes through textContent.
import { message } from './i18n.js';
import { groupsFor } from './popup-state.js';
export function glyphButton(key, glyph) {
  const node = document.createElement('button'); node.type = 'button'; node.className = 'kf-icon-button';
  node.title = message(key); node.setAttribute('aria-label', message(key));
  const icon = document.createElement('span'); icon.className = `kf-icon glyph-${glyph}`; icon.setAttribute('aria-hidden', 'true'); node.append(icon);
  return node;
}
// A code-only row (verification-code field) fills just the code, so it has no separate code action.
export function loginRow(entry, { codeOnly = false } = {}) {
  const row = document.createElement('li'); row.className = 'kf-row';
  const login = document.createElement('button'); login.type = 'button'; login.className = 'login kf-login';
  login.setAttribute('aria-label', codeOnly ? message('fillCodeFor', [entry.title]) : message('fillLogin', [entry.title, entry.username]));
  const avatar = document.createElement('span'); avatar.className = 'kf-avatar'; avatar.setAttribute('aria-hidden', 'true'); avatar.textContent = entry.title.trim().slice(0, 1).toLocaleUpperCase() || '·';
  const label = document.createElement('span'); label.className = 'kf-label';
  const title = document.createElement('strong'); title.className = 'kf-title'; title.textContent = entry.title; title.title = entry.title; title.dir = 'auto';
  const username = document.createElement('span'); username.className = 'kf-username'; username.textContent = entry.username; username.title = entry.username; username.dir = 'auto';
  label.append(title, username); login.append(avatar, label);
  if (entry.hasTotp && !codeOnly) { const badge = document.createElement('span'); badge.className = 'kf-icon kf-code'; badge.setAttribute('role', 'img'); badge.setAttribute('aria-label', message('verificationCode')); badge.title = message('verificationCode'); login.append(badge); }
  row.append(login);
  const code = entry.hasTotp && !codeOnly ? glyphButton('fillCode', 'code') : null;
  const reveal = glyphButton('reveal', 'reveal');
  if (code) row.append(code);
  row.append(reveal);
  return { row, login, code, reveal };
}
export function renderGroups(container, entries, makeRow) {
  let otherHeading = false;
  for (const group of groupsFor(entries)) {
    if (!group.exact && !otherHeading) { const heading = document.createElement('h2'); heading.className = 'kf-section'; heading.textContent = message('otherLogins'); container.append(heading); otherHeading = true; }
    if (group.name !== null) { const heading = document.createElement('h3'); heading.className = 'kf-section'; heading.textContent = group.name; container.append(heading); }
    const list = document.createElement('ul');
    for (const entry of group.entries) list.append(makeRow(entry));
    container.append(list);
  }
}
