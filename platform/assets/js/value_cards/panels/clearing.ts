import type {ValuePanel} from "../panel"

/** Fair price: the clearing panel, every winning bid filled to one price. */
export const clearing: ValuePanel = {
  colours: ["#a33208", "#ff5b19", "#ffe0c7"],
  pitch: [9, 9],
  stillAt: 3,
  body: /* wgsl */ `
  let bars = 9.0;
  let k = min(floor(x * bars), bars - 1.0);
  let f = fract(x * bars);
  let inBar = step(0.14, f) * step(f, 0.86);
  let limit = 0.18 + 0.72 * noise(vec2f(k * 1.7 + 3.0, t * 0.22));
  let price = mix(0.46 + 0.1 * sin(t * 0.31), p.y, p.z);
  let wins = step(price, limit);
  let paid = step(y, price) * wins;
  let spare = step(price, y) * step(y, limit) * wins;
  let lost = step(y, limit) * (1.0 - wins);
  let line = 1.0 - step(0.5 / g.count.y, abs(y - price));
  let amount = max(inBar * max(max(paid * 0.9, spare * 0.24), lost * 0.2), line);
  let tone = max(inBar * max(max(paid * 0.62, spare * 0.3), lost * 0.12), line);
  let d = mix(mix(9.0, sdBox(g.local, vec2f(3.4, 3.4), 0.5), inBar), sdBox(g.local, vec2f(4.4, 1.3), 0.6), line);
  return emit(g, d, ramp(tone), amount);
`,
}
