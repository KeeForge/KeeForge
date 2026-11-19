import { PopupState, groupsFor } from './popup-state.js';
import { message, reason, localizePage } from './i18n.js';
localizePage();
const send = request => chrome.runtime.sendMessage(request);
const model = new PopupState(send);
const status = document.querySelector('#status'), content = document.querySelector('#content'), site = document.querySelector('#site');
function button(label, action) {
  const node = document.createElement('button'); node.className = 'kf-primary'; node.type = 'button'; node.textContent = label;
  node.addEventListener('click', () => void action()); return node;
}
function iconButton(key, glyph, action) {
  const node = button('', action); node.className = 'kf-icon-button';
  node.title = message(key); node.setAttribute('aria-label', message(key));
  const icon = document.createElement('span'); icon.className = `kf-icon glyph-${glyph}`; icon.setAttribute('aria-hidden', 'true'); node.append(icon);
  return node;
}
async function action(type, fields = {}) {
  try {
    const reply = await send({ type, ...fields });
    if (reply.ok === false) { model.reply(reply); render(); }
    else if (type === 'launchApp') await load();
    else window.close();
  } catch { model.reply({ ok: false, error: 'unavailable' }); render(); }
}
async function fill(index, totp = false) {
  const pending = model.fill(index, totp); render();
  if (await pending) window.close(); else render();
}
function render() {
  content.replaceChildren(); status.textContent = '';
  const host = model.target ? new URL(model.target.origin).host : '';
  site.textContent = host; site.title = host;
  document.querySelector('#secure').hidden = !model.target?.origin.startsWith('https:');
  document.querySelector('#frame').hidden = !model.target || model.target.frameId === 0;
  const state = model.state;
  status.textContent = message({ loading: 'loading', 'host-missing': 'hostMissing', 'app-unavailable': 'appUnavailable', unpaired: 'notPaired', pairing: 'pairBusy', locked: 'locked', confirm: 'confirm', empty: 'noLogins', done: 'filled' }[state] || 'loading', state === 'empty' && model.target ? new URL(model.target.origin).host : undefined);
  if (state === 'error') status.textContent = reason(model.error);
  document.querySelector('#state').hidden = state === 'matches';
  const glyph = document.querySelector('#state-icon');
  const glyphs = { locked: 'lock', empty: 'key', done: 'check', 'app-unavailable': 'power', unpaired: 'link', pairing: 'link' };
  glyph.className = ['loading', 'confirm'].includes(state) ? 'kf-waiting' : `kf-icon kf-state-icon glyph-${glyphs[state] || (state === 'error' && ['bad-origin', 'no-fields'].includes(model.error) ? 'page' : 'alert')}`;
  if (['app-unavailable', 'empty'].includes(state)) content.append(button(message('openApp'), () => action('launchApp')));
  if (state === 'unpaired') content.append(button(message('pair'), async () => { await chrome.tabs.create({ url: chrome.runtime.getURL('pair.html') }); window.close(); }));
  if (state === 'locked') content.append(button(message('unlock'), () => action('unlock')));
  if (['error', 'host-missing'].includes(state)) content.append(button(message('tryAgain'), load));
  if (state !== 'matches') return;
  status.textContent = '';
  let index = 0, otherHeading = false;
  for (const group of groupsFor(model.entries)) {
    if (!group.exact && !otherHeading) { const heading = document.createElement('h2'); heading.className = 'kf-section'; heading.textContent = message('otherLogins'); content.append(heading); otherHeading = true; }
    if (group.name !== null) { const heading = document.createElement('h3'); heading.className = 'kf-section'; heading.textContent = group.name; content.append(heading); }
    const list = document.createElement('ul');
    for (const entry of group.entries) {
      const current = index++;
      const row = document.createElement('li'); row.className = 'kf-row'; row.dataset.selected = String(current === model.selected);
      const primary = button('', () => fill(current)); primary.className = 'login kf-login'; primary.dataset.index = current;
      primary.setAttribute('aria-label', message('fillLogin', [entry.title, entry.username]));
      primary.addEventListener('focus', () => {
        model.selected = current;
        for (const item of content.querySelectorAll('.kf-row')) item.dataset.selected = String(item === row);
      });
      const avatar = document.createElement('span'); avatar.className = 'kf-avatar'; avatar.setAttribute('aria-hidden', 'true'); avatar.textContent = entry.title.trim().slice(0, 1).toLocaleUpperCase() || '·';
      const label = document.createElement('span'); label.className = 'kf-label';
      const title = document.createElement('strong'); title.className = 'kf-title'; title.textContent = entry.title; title.title = entry.title; title.dir = 'auto';
      const username = document.createElement('span'); username.className = 'kf-username'; username.textContent = entry.username; username.title = entry.username; username.dir = 'auto';
      label.append(title, username); primary.append(avatar, label);
      if (entry.hasTotp) { const badge = document.createElement('span'); badge.className = 'kf-icon kf-code'; badge.setAttribute('role', 'img'); badge.setAttribute('aria-label', message('verificationCode')); badge.title = message('verificationCode'); primary.append(badge); }
      row.append(primary);
      if (entry.hasTotp) row.append(iconButton('fillCode', 'code', () => fill(current, true)));
      row.append(iconButton('reveal', 'reveal', () => action('reveal', { entry: entry.entry, db: entry.db })));
      list.append(row);
    }
    content.append(list);
  }
}
document.addEventListener('keydown', event => {
  if (model.state !== 'matches') return;
  if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
    event.preventDefault(); model.move(event.key); content.querySelector(`[data-index="${model.selected}"]`)?.focus();
  } else if (event.key === 'Enter' && (event.target === document.body || event.target === document.documentElement)) { event.preventDefault(); void fill(); }
});
async function load() {
  try {
    model.state = 'loading'; model.entries = []; model.target = null; site.textContent = ''; render();
    await model.load();
    render();
  } catch { model.reply({ ok: false, error: 'bad-origin' }); render(); }
}
render(); void load();
