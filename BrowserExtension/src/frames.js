export { fillDocument as probeFrame } from './fill.js';
export function chooseFrame(probes) {
  return probes.find(p => !p.error && p.result?.focused === true && p.result?.fillable === true)?.frameId ?? 0;
}
