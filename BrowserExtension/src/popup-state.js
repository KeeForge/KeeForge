export function groupsFor(entries) {
  const multiple = new Set(entries.map(e => e.db)).size > 1;
  const groups = [];
  for (const exact of [true, false]) {
    const section = entries.filter(e => e.exact === exact);
    const databases = [...new Set(section.map(e => e.db))].sort((a, b) => section.find(e => e.db === a).dbName.localeCompare(section.find(e => e.db === b).dbName));
    for (const db of databases) groups.push({ exact, name: multiple ? section.find(e => e.db === db).dbName : null, entries: section.filter(e => e.db === db) });
  }
  return groups;
}
export class PopupState {
  constructor(send) { this.send = send; this.state = 'loading'; this.entries = []; this.selected = 0; this.target = null; }
  reply(reply) {
    this.entries = []; this.selected = 0; this.error = null;
    if (reply.state) { this.state = reply.state; this.error = reply.reason; }
    else if (reply.ok === false) { this.state = reply.error === 'locked' ? 'locked' : 'error'; this.error = reply.error; }
    else if (Array.isArray(reply.entries)) {
      this.entries = groupsFor(reply.entries).flatMap(group => group.entries);
      this.state = this.entries.length ? 'matches' : reply.locked > 0 ? 'locked' : 'empty';
    } else { this.state = 'error'; this.error = 'unavailable'; }
  }
  move(key) {
    if (this.state !== 'matches' || !this.entries.length) return;
    if (key === 'ArrowDown') this.selected = (this.selected + 1) % this.entries.length;
    if (key === 'ArrowUp') this.selected = (this.selected + this.entries.length - 1) % this.entries.length;
  }
  async fill(index = this.selected, totp = false) {
    if (this.state !== 'matches') return false;
    const entry = this.entries[index];
    if (!entry || !this.target || (totp && !entry.hasTotp)) return false;
    const request = { type: 'fill', tabId: this.target.tabId, frameId: this.target.frameId, entry: entry.entry, db: entry.db, ...(totp ? { totp: true } : {}) };
    this.state = 'confirm';
    try {
      const reply = await this.send(request);
      if (reply.ok === true) { this.entries = []; this.target = null; this.selected = 0; this.state = 'done'; return true; }
      this.reply(reply);
    } catch { this.reply({ ok: false, error: 'unavailable' }); }
    return false;
  }
}
