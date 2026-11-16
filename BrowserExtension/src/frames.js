export function probeFrame() {
  const fields = [...document.querySelectorAll('input')].filter(input => {
    if (input.disabled || input.matches?.(':disabled') || input.readOnly || input.hidden || !['text', 'email', 'tel', 'password', 'number', 'search', 'url', ''].includes(input.type)) return false;
    for (let node = input; node; node = node.parentElement) {
      if (getComputedStyle(node).opacity === '0') return false;
    }
    const box = input.getBoundingClientRect(), style = getComputedStyle(input);
    return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse' && Number(style.opacity) !== 0 && input.getClientRects().length > 0 && box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
  });
  return { focused: document.hasFocus() && fields.includes(document.activeElement), fillable: fields.length > 0 };
}
export function chooseFrame(probes) {
  return probes.find(p => !p.error && p.result?.focused === true && p.result?.fillable === true)?.frameId ?? 0;
}
