import { PopupState, groupsFor } from './popup-state.js';
import { message, reason, localizePage } from './i18n.js';
localizePage();
const send = request => chrome.runtime.sendMessage(request);
const model = new PopupState(send);
const status = document.querySelector('#status'), content = document.querySelector('#content'), site = document.querySelector('#site');
function button(label, action) {
  const node = document.createElement('button'); node.type = 'button'; node.textContent = label;
  node.addEventListener('click', () => void action()); return node;
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
  site.textContent = model.target ? `${model.target.origin}${model.target.frameId === 0 ? '' : ' — ' + message('inFrame')}` : '';
  const state = model.state;
  status.textContent = message({ loading: 'loading', 'host-missing': 'hostMissing', 'app-unavailable': 'appUnavailable', unpaired: 'notPaired', pairing: 'pairBusy', locked: 'unlock', confirm: 'confirm', empty: 'noLogins', done: 'filled' }[state] || 'loading', state === 'empty' && model.target ? new URL(model.target.origin).host : undefined);
  if (state === 'error') status.textContent = reason(model.error);
  if (['app-unavailable', 'empty'].includes(state)) content.append(button(message('openApp'), () => action('launchApp')));
  if (state === 'unpaired') content.append(button(message('pair'), async () => { await chrome.tabs.create({ url: chrome.runtime.getURL('pair.html') }); window.close(); }));
  if (state === 'locked') content.append(button(message('unlock'), () => action('unlock')));
  if (['error', 'host-missing', 'app-unavailable'].includes(state)) content.append(button(message('tryAgain'), load));
  if (state !== 'matches') return;
  status.textContent = '';
  let index = 0, otherHeading = false;
  for (const group of groupsFor(model.entries)) {
    if (!group.exact && !otherHeading) { const heading = document.createElement('h2'); heading.textContent = message('otherLogins'); content.append(heading); otherHeading = true; }
    if (group.name !== null) { const heading = document.createElement('h3'); heading.textContent = group.name; content.append(heading); }
    const list = document.createElement('ul');
    for (const entry of group.entries) {
      const current = index++;
      const row = document.createElement('li');
      const primary = button('', () => fill(current)); primary.className = 'login'; primary.dataset.index = current;
      primary.setAttribute('aria-label', message('fillLogin', [entry.title, entry.username]));
      primary.addEventListener('focus', () => { model.selected = current; });
      if (entry.hasTotp) { const icon = document.createElement('img'); icon.src = 'images/key.svg'; icon.alt = message('verificationCode'); primary.append(icon); }
      const title = document.createElement('strong'); title.textContent = entry.title;
      const username = document.createElement('span'); username.textContent = entry.username;
      primary.append(title, username); row.append(primary);
      if (entry.hasTotp) row.append(button(message('fillCode'), () => fill(current, true)));
      row.append(button(message('reveal'), () => action('reveal', { entry: entry.entry, db: entry.db })));
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
