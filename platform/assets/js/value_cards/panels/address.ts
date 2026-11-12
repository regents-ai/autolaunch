import type {ValuePanel} from "../panel"

/** Stock tokens: the address panel, contract addresses read one character at a time. */
export const address: ValuePanel = {
  colours: ["#145c3b", "#00c805", "#e5e3d2"],
  pitch: [7, 10],
  stillAt: 10.2,
  body: /* wgsl */ `
  let col = g.id.x;
  let line = floor(g.id.y / 2.0);
  let onLine = 1.0 - step(0.5, g.id.y - line * 2.0);
  let lines = max(floor(g.count.y / 2.0), 1.0);
  let inText = step(1.0, col) * step(col, g.count.x - 2.0) * onLine;
  let passes = floor(t * 0.45);
  let current = passes - floor(passes / lines) * lines;
  let cursor = 1.0 + floor(fract(t * 0.45) * (g.count.x - 2.0));
  let here = 1.0 - step(0.5, abs(line - current));
  let done = step(line + 0.5, current);
  let typed = here * step(col, cursor - 0.5);
  let tip = here * (1.0 - step(0.5, abs(col - cursor)));
  let held = p.z * (1.0 - step(0.5, abs(line - floor((1.0 - p.y) * g.count.y / 2.0))));
  let amount = inText * max(max(0.12, done * 0.4), max(max(typed * 0.86, tip), held * 0.95));
  let tone = inText * max(max(0.2, done * 0.45), max(max(typed * 0.68, tip), held * 0.8));
  let kind = floor(hash(vec2f(col, line)) * 4.0);
  let zero = abs(sdBox(g.local, vec2f(2.0, 3.4), 1.6)) - 0.7;
  let ex = min(sdSlash(g.local, 2.4, 0.7, 1.0), sdSlash(g.local, 2.4, 0.7, -1.0));
  let other = select(select(select(sdDiamond(g.local, 2.8), sdPlus(g.local, 2.4, 0.8), kind < 2.5), sdSlash(g.local, 3.2, 0.8, 1.0), kind < 1.5), sdBox(g.local, vec2f(2.0, 3.4), 0.6), kind < 0.5);
  let glyph = select(select(other, ex, col < 2.5), zero, col < 1.5);
  return emit(g, mix(9.0, glyph, inText), ramp(tone), amount);
`,
}
