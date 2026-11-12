import type {ValuePanel} from "../panel"

/** Locked liquidity: the vault panel, a sealed pool that only lets its fees rise out. */
export const vault: ValuePanel = {
  colours: ["#0052ff", "#4fd3ec", "#e5e3d2"],
  pitch: [8, 8],
  stillAt: 2,
  body: /* wgsl */ `
  let cx = g.id.x;
  let cy = g.count.y - 1.0 - g.id.y;
  let left = floor(g.count.x * 0.12);
  let right = g.count.x - 1.0 - left;
  let bottom = floor(g.count.y * 0.08);
  let lid = floor(g.count.y * 0.72);
  let across = step(left, cx) * step(cx, right);
  let side = max(1.0 - step(0.5, abs(cx - left)), 1.0 - step(0.5, abs(cx - right))) * step(bottom, cy) * step(cy, lid);
  let ends = max(1.0 - step(0.5, abs(cy - bottom)), 1.0 - step(0.5, abs(cy - lid))) * across;
  let wall = max(side, ends);
  let inside = step(left + 1.0, cx) * step(cx, right - 1.0) * step(bottom + 1.0, cy) * step(cy, lid - 1.0);
  let tilt = p.z * (x - 0.5) * (p.x - 0.5) * 0.9;
  let level = bottom + (lid - bottom) * (0.6 + 0.08 * sin(x * 7.0 + t * 1.4) + 0.035 * sin(x * 15.0 - t * 2.1) + tilt);
  let water = inside * step(cy, level);
  let surface = water * step(level - 1.0, cy);
  let depth = sat((cy - bottom) / max(level - bottom, 1.0));
  let fee = step(0.7, hash(vec2f(cx, 7.0))) * step(left + 1.0, cx) * step(cx, right - 1.0);
  let rise = fract(t * (0.16 + 0.1 * hash(vec2f(cx, 9.0))) + hash(vec2f(cx, 3.0)));
  let above = g.count.y - 2.0 - lid;
  let drop = fee * step(lid + 0.5, cy) * (1.0 - step(0.5, abs(cy - (lid + 1.0 + floor(rise * above)))));
  let amount = max(max(wall * 0.72, water * (0.3 + 0.4 * depth)), max(surface * 0.95, drop * (1.0 - rise * 0.6)));
  let tone = max(max(wall * 0.5, water * (0.2 + 0.4 * depth)), max(surface * 0.85, drop));
  let bead = length(g.local) - mix(1.2, 3.2, max(water, drop));
  let d = mix(mix(9.0, bead, max(water, drop)), sdBox(g.local, vec2f(3.0, 3.0), 0.4), wall);
  return emit(g, d, ramp(tone), amount);
`,
}
