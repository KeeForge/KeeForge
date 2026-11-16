export const message = (key, substitutions) => chrome.i18n.getMessage(key, substitutions);
const reasons = {
  'host-missing': 'hostMissing', 'not-running': 'appUnavailable', 'closed': 'appUnavailable',
  'pairing-declined': 'pairDeclined', 'pairing-busy': 'pairBusy', timeout: 'timeout',
  'target-required': 'notOffered', 'bad-origin': 'badOrigin', 'no-fields': 'noFields', 'no-match': 'noLongerMatches',
  locked: 'unlock', denied: 'denied', 'not-offered': 'notOffered', 'rate-limited': 'rateLimited',
  disabled: 'disabled', unpaired: 'pair', disconnected: 'disconnected'
};
export const reason = code => message(reasons[code] || 'unavailable');
export function localizePage() {
  document.documentElement.lang = chrome.i18n.getUILanguage();
  for (const node of document.querySelectorAll('[data-i18n]')) node.textContent = message(node.dataset.i18n);
  document.title = message('extensionName');
}
