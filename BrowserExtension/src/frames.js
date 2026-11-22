export { fillDocument as probeFrame } from './fill.js';
// The toolbar popup can take focus from the page, so fall back to the frame the user last touched if a field is still its active element.
export function chooseFrame(probes) {
  const usable = probes.filter(p => !p.error && p.result?.fillable === true);
  const focused = usable.find(p => p.result.focused === true);
  if (focused) return focused.frameId;
  const last = probes.filter(p => !p.error && p.result?.touched > 0).sort((a, b) => b.result.touched - a.result.touched)[0];
  return last && usable.includes(last) && last.result.active === true ? last.frameId : 0;
}
