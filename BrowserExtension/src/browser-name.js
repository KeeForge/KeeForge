export async function browserName(navigator, fallback = 'Browser') {
  const brands = navigator.userAgentData?.brands?.map(value => value.brand).join(' ') || '';
  const ua = `${brands} ${navigator.userAgent}`;
  if (/Firefox/i.test(ua)) return 'Firefox';
  if (/Edg|Microsoft Edge/i.test(ua)) return 'Edge';
  if (/Vivaldi/i.test(ua)) return 'Vivaldi';
  if (/Arc[ /]/i.test(ua)) return 'Arc';
  if (/Brave/i.test(ua)) return 'Brave';
  try { if (await navigator.brave?.isBrave()) return 'Brave'; } catch { /* Optional browser label only. */ }
  return /Chrome|Chromium/i.test(ua) ? 'Chrome' : fallback;
}
