// Headless, disposable Chrome for artwork and extension-page visual checks.
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
export const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function launchChrome() {
  const profile = await mkdtemp(join(tmpdir(), 'keeforge-ui-'));
  const child = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    '--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--enable-unsafe-extension-debugging',
    '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update',
    '--disable-sync', '--disable-default-apps', '--use-mock-keychain', '--password-store=basic',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', 'about:blank'
  ], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
  let buffer = '', next = 0;
  const pending = new Map();
  child.stdio[3].on('error', () => {});
  child.stderr.resume();
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    for (let end; (end = buffer.indexOf('\0')) >= 0;) {
      const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      const request = pending.get(message.id);
      if (request) { pending.delete(message.id); clearTimeout(request.timer); message.error ? request.reject(new Error(`${request.method}: ${message.error.message}`)) : request.resolve(message.result); }
    }
  });
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    if (exitInfo) { reject(exitInfo); return; }
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timeout: ${method}`)); }, 15000);
    pending.set(id, { resolve, reject, timer, method });
    child.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  });
  let exitInfo;
  const exited = new Promise(resolve => {
    const failed = error => {
      exitInfo = error;
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
      pending.clear(); resolve();
    };
    child.once('error', failed);
    child.once('exit', (code, signal) => failed(new Error(`Chrome exited before close (${signal || code})`)));
  });
  const close = async () => {
    if (exitInfo) { await rm(profile, { recursive: true, force: true }); return; }
    child.kill('SIGTERM');
    let timer;
    await Promise.race([exited, new Promise(resolve => { timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000); })]);
    clearTimeout(timer);
    await exited;
    await rm(profile, { recursive: true, force: true });
  };
  return { send, close, async tab() {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    const call = (method, params) => send(method, params, sessionId);
    await call('Page.enable');
    return { call, async evaluate(expression) {
      const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
      return result.result.value;
    }, close: () => send('Target.closeTarget', { targetId }) };
  } };
}
