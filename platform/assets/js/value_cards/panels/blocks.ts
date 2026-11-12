import type {ValuePanel} from "../panel"

/** Onchain: the blocks panel, new blocks arriving on the right as the chain grows. */
export const blocks: ValuePanel = {
  colours: ["#365d62", "#aecacd", "#e5e3d2"],
  pitch: [10, 10],
  stillAt: 2,
  body: /* wgsl */ `
  let size = 4.0;
  let moved = floor(t * 2.5);
  let along = g.id.x + moved;
  let bx = floor(along / size);
  let wx = along - bx * size;
  let by = floor(g.id.y / size);
  let wy = g.id.y - by * size;
  let there = step(0.3, hash(vec2f(bx, by)));
  let inBlock = step(wx, 2.5) * step(wy, 2.5) * there;
  let link = (1.0 - step(0.5, abs(wx - 3.0))) * (1.0 - step(0.5, abs(wy - 1.0))) * there * step(0.3, hash(vec2f(bx + 1.0, by)));
  let data = dith(vec2f(along, g.id.y), 0.35 + 0.5 * hash(vec2f(bx, by + 11.0)));
  let fresh = smoothstep(0.72, 1.0, x);
  let held = p.z * (1.0 - step(0.5, abs(bx - floor((p.x * g.count.x + moved) / size)))) * (1.0 - step(0.5, abs(by - floor((1.0 - p.y) * g.count.y / size))));
  let lit = inBlock * mix(0.22, 0.8, data);
  let amount = max(max(lit * (0.6 + 0.4 * fresh), inBlock * held), link * 0.3);
  let tone = max(max(inBlock * (0.25 + 0.35 * data + 0.4 * fresh), inBlock * held), link * 0.3);
  let glyph = select(sdBox(g.local, vec2f(4.2, 1.0), 0.5), sdBox(g.local, vec2f(3.6, 3.6), 0.6), inBlock > 0.5);
  return emit(g, mix(9.0, glyph, max(inBlock, link)), ramp(tone), amount);
`,
}
