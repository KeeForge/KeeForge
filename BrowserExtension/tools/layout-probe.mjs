// Evaluated in an extension page by the visual checks; returns a list of problems (empty when the page is sound).
// Nothing past the viewport's sides, no clipped text except deliberate ellipsis or a
// scroll container, and WCAG AA contrast (4.5:1) for visible, non-decorative text against its painted background.
export const layoutProbe = `(() => {
  const found = [], width = document.documentElement.clientWidth, name = e => e.id ? '#' + e.id : e.className ? '.' + String(e.className).split(' ')[0] : e.tagName;
  const rgba = value => { const m = value.match(/[\\d.]+/g)?.map(Number) || [0, 0, 0, 0]; return m.length === 3 ? [...m, 1] : m; };
  const background = e => { const layers = []; for (let n = e; n; n = n.parentElement) { const c = rgba(getComputedStyle(n).backgroundColor); if (c[3]) layers.push(c); if (c[3] === 1) break; } return layers.reduceRight((under, [r, g, b, a]) => [r * a + under[0] * (1 - a), g * a + under[1] * (1 - a), b * a + under[2] * (1 - a)], [255, 255, 255]); };
  const luminance = c => { const [r, g, b] = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  if (document.documentElement.scrollWidth > width) found.push('page scrolls horizontally: ' + document.documentElement.scrollWidth + ' > ' + width);
  for (const e of document.querySelectorAll('body *')) {
    const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    if (!r.width || s.visibility === 'hidden') continue;
    if (r.right > width + 0.5 || r.left < -0.5) found.push(name(e) + ' extends past the viewport (' + Math.round(r.left) + '..' + Math.round(r.right) + ' of ' + width + ')');
    if (e.clientWidth && e.scrollWidth > e.clientWidth + 1 && s.textOverflow !== 'ellipsis' && !['auto', 'scroll'].includes(s.overflowX)) found.push(name(e) + ' clips its content (' + e.scrollWidth + ' > ' + e.clientWidth + ')');
    if ([...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && Number(s.opacity) === 1 && !e.closest('[aria-hidden="true"]')) {
      const fg = rgba(s.color), bg = background(e), mixed = fg.slice(0, 3).map((v, i) => v * fg[3] + bg[i] * (1 - fg[3]));
      const [hi, lo] = [luminance(mixed), luminance(bg)].sort((a, b) => b - a), ratio = (hi + 0.05) / (lo + 0.05);
      if (ratio < 4.5) found.push(name(e) + ' text contrast ' + ratio.toFixed(2) + ':1');
    }
  }
  return found;
})()`;
