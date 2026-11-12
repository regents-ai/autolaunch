import type {ValuePanel} from "../panel"

/** Agents: the handoff panel, a form an agent fills in and a person seals. */
export const handoff: ValuePanel = {
  colours: ["#754600", "#f5c16c", "#e5e3d2"],
  pitch: [9, 9],
  stillAt: 7.7,
  body: /* wgsl */ `
  let asp = aspect();
  let cycle = fract(t * 0.11);
  let field = floor(g.id.y / 7.0);
  let row = g.id.y - field * 7.0;
  let size = 0.24 + 0.22 * hash(vec2f(field, 4.0));
  let filling = sat((cycle - field * 0.12) / 0.12);
  let band = step(1.5, row) * step(row, 3.5) * step(field, 4.0) * step(0.08, x) * step(x, 0.08 + size);
  let filled = band * step(x, 0.08 + size * filling);
  let edge = band * (1.0 - step(0.6 / g.count.x, abs(x - (0.08 + size * filling)))) * step(0.001, filling) * (1.0 - step(0.999, filling));
  let here = (g.at - vec2f(0.78, 0.5)) * asp;
  let ring = 1.0 - step(0.02, abs(length(here) - 0.15));
  let tick = 1.0 - step(0.022, min(sdSeg(here, vec2f(-0.065, 0.0), vec2f(-0.018, -0.05)), sdSeg(here, vec2f(-0.018, -0.05), vec2f(0.07, 0.06))));
  let seal = max(sat((cycle - 0.66) / 0.06), p.z * step(0.6, p.x));
  let fade = 1.0 - smoothstep(0.93, 1.0, cycle);
  let amount = max(max(band * 0.16, filled * 0.75 * fade), max(max(edge, ring * (0.35 + 0.6 * seal)), tick * seal * fade));
  let tone = max(max(band * 0.2, filled * 0.55), max(max(edge * 0.95, ring * (0.4 + 0.5 * seal)), tick * seal));
  let glyph = select(sdBox(g.local, vec2f(3.6, 2.4), 0.8), length(g.local) - 3.0, x > 0.6);
  return emit(g, mix(9.0, glyph, max(max(band, ring), tick * seal)), ramp(tone), amount);
`,
}
