/**
 * The home product cards' panels: for each one its colour gradient (deep, main,
 * bright), the moment its still frame shows, and its shader. Covered calls
 * draws a call's payoff, Memestock two colours leaning towards each other
 * along a seam, Revstake columns tipped in the card's colour.
 *
 * This file imports nothing, so the script that draws the still frames
 * (`stills.mjs`, beside it) reads the same colours and shaders the site does.
 * After changing anything here, draw the stills again: `npm run stills:home`.
 */

/** The panel's ground. The card's stylesheet paints the same colour behind it. */
export const ground = "#08080a"

/**
 * The three shapes a panel takes, as the CSS pixels its cells are laid out
 * for: square in a row of three, broad in a row of one or two, a strip on a
 * phone. A panel of any other size shows the same picture, scaled, so the still
 * frame drawn at these sizes always matches it.
 */
export const shapes = {square: [300, 300], broad: [450, 300], strip: [360, 144]} as const

export const shapeFor = (width: number, height: number) => {
  const across = width / height
  return across > 2 ? shapes.strip : across > 1.25 ? shapes.broad : shapes.square
}

/** A hex colour as linear-light channels, which is what the shaders mix. */
export const rgba = (hex: string) => {
  const linear = (channel: number) => (channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4)
  return [1, 3, 5].map(at => linear(Number.parseInt(hex.slice(at, at + 2), 16) / 255)).concat(1)
}

const common = /* wgsl */ `
// One card's panel: a ground, a three-stop colour gradient (deep, main, bright),
// the pointer (x, y, how present it is) and the size (width, height, device
// pixels per CSS pixel, seconds).
struct Params {
  ground: vec4f,
  a: vec4f,
  b: vec4f,
  c: vec4f,
  pointer: vec4f,
  size: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

const TAU = 6.2831853;

fn sq(v: f32) -> f32 { return v * v; }
fn sat(v: f32) -> f32 { return clamp(v, 0.0, 1.0); }
// A 0..1 value for a whole-numbered place, by integer arithmetic so every GPU agrees.
fn hash(p: vec2f) -> f32 {
  let q = vec2u(vec2i(floor(p)));
  var n = (q.x * 1597334677u) ^ (q.y * 3812015801u);
  n = (n ^ (n >> 16u)) * 2246822519u;
  n = n ^ (n >> 13u);
  return f32(n >> 8u) / 16777216.0;
}
fn noise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), u.x), mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), u.x), u.y);
}
fn time() -> f32 { return params.size.w; }
// The pointer across the frame with y up, and how present it is.
fn pointer() -> vec3f { return vec3f(params.pointer.x, 1.0 - params.pointer.y, params.pointer.z); }

// Linear sRGB to OKLab and back (Björn Ottosson's matrices).
fn toOklab(c: vec3f) -> vec3f {
  let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
  let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
  let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
  let r = pow(max(vec3f(l, m, s), vec3f(0.0)), vec3f(1.0 / 3.0));
  return vec3f(
    0.2104542553 * r.x + 0.7936177850 * r.y - 0.0040720468 * r.z,
    1.9779984951 * r.x - 2.4285922050 * r.y + 0.4505937099 * r.z,
    0.0259040371 * r.x + 0.7827717662 * r.y - 0.8086757660 * r.z,
  );
}
fn fromOklab(lab: vec3f) -> vec3f {
  let l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
  let m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
  let s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
  let c = vec3f(l * l * l, m * m * m, s * s * s);
  return vec3f(
    4.0767416621 * c.x - 3.3077115913 * c.y + 0.2309699292 * c.z,
    -1.2684380046 * c.x + 2.6097574011 * c.y - 0.3413193965 * c.z,
    -0.0041960863 * c.x - 0.7034186147 * c.y + 1.7076147010 * c.z,
  );
}
// The card's gradient, deep through main to bright, mixed in OKLab so it never
// dips through grey on the way.
fn ramp(t: f32) -> vec3f {
  let u = sat(t) * 2.0;
  if (u < 1.0) { return fromOklab(mix(toOklab(params.a.rgb), toOklab(params.b.rgb), u)); }
  return fromOklab(mix(toOklab(params.b.rgb), toOklab(params.c.rgb), u - 1.0));
}
// Linear light to the screen's sRGB.
fn toSrgb(c: vec3f) -> vec3f {
  return select(1.055 * pow(c, vec3f(1.0 / 2.4)) - vec3f(0.055), c * 12.92, c <= vec3f(0.0031308));
}

// Glyph shapes: signed distances in CSS pixels from the cell's centre, y up.
fn sdBox(p: vec2f, half: vec2f, r: f32) -> f32 {
  let q = abs(p) - half + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
fn sdDiamond(p: vec2f, r: f32) -> f32 { return (abs(p.x) + abs(p.y) - r) * 0.70710678; }
// A slash leaning right (dir 1) or left (dir -1).
fn sdSlash(p: vec2f, len: f32, thick: f32, dir: f32) -> f32 {
  let along = (p.x + dir * p.y) * 0.70710678;
  let across = (p.y - dir * p.x) * 0.70710678;
  return sdBox(vec2f(along, across), vec2f(len, thick), thick);
}

struct Grid { id: vec2f, count: vec2f, at: vec2f, local: vec2f, mask: f32 }
// The grid of cells inside an inset frame: which cell this pixel is in, how many
// there are, the cell's centre as 0..1 across the frame (y up), and this pixel's
// offset from that centre in CSS pixels (y up).
fn grid(uv: vec2f, pitch: vec2f) -> Grid {
  let s = params.size.z;
  let inset = 10.0 * s;
  let area = params.size.xy - vec2f(inset * 2.0);
  let count = max(floor(area / (pitch * s)), vec2f(1.0));
  let room = area / count;
  let px = uv * params.size.xy - vec2f(inset);
  let id = clamp(floor(px / room), vec2f(0.0), count - vec2f(1.0));
  let off = (px - (id + vec2f(0.5)) * room) / s;
  let mask = step(0.0, px.x) * step(0.0, px.y) * step(px.x, area.x) * step(px.y, area.y);
  let at = vec2f((id.x + 0.5) / count.x, 1.0 - (id.y + 0.5) / count.y);
  return Grid(id, count, at, vec2f(off.x, -off.y), mask);
}
// Ordered dither across cells, by the 4x4 Bayer matrix: is this cell on, for a value 0..1.
fn dith(id: vec2f, v: f32) -> f32 {
  var bayer = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
  let at = vec2u(id) & vec2u(3u);
  return step((bayer[at.y * 4u + at.x] + 0.5) / 16.0, v);
}

// Paints one cell: an unlit glyph is a faint tint of the card's deep colour, a
// lit one takes its colour and glows a little into the gap.
fn emit(g: Grid, d: f32, colour: vec3f, amount: f32) -> vec4f {
  let s = params.size.z;
  let k = sat(amount);
  let cover = (1.0 - smoothstep(-0.6 / s, 0.6 / s, d)) * g.mask;
  let halo = exp(-max(d, 0.0) / 2.4) * (1.0 - cover) * g.mask;
  let ground = params.ground.rgb;
  let unlit = mix(ground, params.a.rgb, 0.2);
  let face = mix(ground, mix(unlit, colour, k), cover);
  return vec4f(toSrgb(clamp(face + colour * halo * k * k * 0.1, vec3f(0.0), vec3f(1.0))), 1.0);
}
`

export const panels = {
  // A call's payoff: flat along the premium, then rising past the strike. The pointer sets the strike.
  payoff: {
    deep: "#7a1200",
    main: "#ff5b19",
    bright: "#ffe0c7",
    stillAt: 2.4,
    shader: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let g = grid(uv, vec2f(8.0, 8.0));
  let p = pointer();
  let t = time();
  let x = g.at.x;
  let y = g.at.y;
  let drift = 0.46 + 0.16 * sin(t * 0.55) + 0.05 * sin(t * 1.3 + 1.0);
  let strike = mix(drift, clamp(p.x, 0.15, 0.85), p.z);
  let payoff = min(0.2 + max(x - strike, 0.0) * 1.7, 0.96);
  let filled = step(y, payoff);
  let top = 1.0 - smoothstep(0.0, 0.16, payoff - y);
  let glint = exp(-sq((x - fract(t * 0.18)) * 9.0));
  var colour = ramp(0.08 + 0.4 * y / payoff + 0.42 * top + 0.2 * glint);
  var amount = filled * (0.8 + 0.2 * top);
  let ghost = (1.0 - step(0.6 / g.count.x, abs(x - strike))) * (1.0 - filled) * dith(g.id, 0.5);
  colour = mix(colour, params.c.rgb, ghost);
  amount = max(amount, ghost * 0.6);
  return emit(g, sdBox(g.local, vec2f(3.0, 3.0), 0.7), colour, amount);
}`,
  },
  // Two colours leaning towards each other along a seam that sways row by row. The seam bends to the pointer.
  seam: {
    deep: "#18b8d6",
    main: "#fbf4e6",
    bright: "#ff4fa3",
    stillAt: 2.0,
    shader: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let g = grid(uv, vec2f(11.0, 11.0));
  let p = pointer();
  let t = time();
  let x = g.at.x;
  let y = g.at.y;
  let row = g.id.y;
  var seam = 0.5 + 0.2 * sin(t * 0.8 + row * 0.42) + 0.08 * sin(t * 1.7 - row * 0.9);
  seam = mix(seam, p.x, exp(-sq((y - p.y) * 3.2)) * p.z);
  let side = smoothstep(seam - 0.16, seam + 0.16, x);
  let meet = exp(-sq((x - seam) * 8.0));
  let knot = 1.0 - step(0.55 / g.count.x, abs(x - seam));
  let d = mix(sdSlash(g.local, 3.9, 1.2, sign(x - seam)), sdDiamond(g.local, 4.6), knot);
  let shimmer = 0.5 + 0.5 * sin(t * 1.4 + hash(g.id) * TAU);
  return emit(g, d, ramp(side), 0.44 + 0.46 * meet + 0.12 * shimmer);
}`,
  },
  // Columns that rise and fall, each tipped in the card's colour. Those under the pointer lift.
  columns: {
    deep: "#35520a",
    main: "#c8f25c",
    bright: "#ffffff",
    stillAt: 2.4,
    shader: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let g = grid(uv, vec2f(8.5, 8.5));
  let p = pointer();
  let t = time();
  let x = g.at.x;
  let y = g.at.y;
  let col = g.id.x;
  let alive = step(0.3, hash(vec2f(col, 3.0)));
  let wave = noise(vec2f(col * 0.22, t * 0.7)) * 0.62 + noise(vec2f(col * 0.9 + 9.0, t * 1.6)) * 0.38;
  let lift = exp(-sq((x - p.x) * 6.0)) * p.z * 0.35;
  let height = clamp((0.1 + wave * 0.85) * mix(0.16, 1.0, alive) + lift, 0.04, 0.97);
  let rowH = 1.0 / g.count.y;
  let filled = step(y, height);
  let tip = step(height - rowH * 3.0, y) * filled;
  let after = step(height, y) * step(y, height + rowH * 2.0);
  var colour = mix(mix(ramp(0.82), params.c.rgb, y / height), ramp(0.5), tip);
  colour = mix(colour, ramp(0.3), after);
  return emit(g, sdBox(g.local, vec2f(3.5, 3.5), 0.3), colour, max(filled, after * 0.45));
}`,
  },
} as const

export type CellPattern = keyof typeof panels
