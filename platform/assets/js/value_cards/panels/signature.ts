import type {ValuePanel} from "../panel"

/** Your wallet: the signature panel, a looped signature written out and underlined. */
export const signature: ValuePanel = {
  colours: ["#393b3e", "#e5e3d2", "#ffffff"],
  pitch: [5, 5],
  stillAt: 6.1,
  body: /* wgsl */ `
  let asp = aspect();
  let cycle = fract(t * 0.14);
  let pen = sat(cycle * 1.35);
  let pull = p.z * (p.y - 0.58) * 0.4;
  let here = g.at * asp;
  var near = 9.0;
  var last = vec2f(0.12, 0.58);
  var tip = last;
  for (var i = 1; i <= 72; i++) {
    let s = f32(i) / 72.0;
    let turn = s * TAU * 4.0;
    let high = 0.13 * (0.7 + 0.3 * sin(s * 7.0 + 1.0));
    let cx = 0.12 + 0.76 * s - 0.06 * sin(turn);
    let point = vec2f(cx, 0.58 + high * cos(turn) + pull * exp(-sq((cx - p.x) * 6.0)));
    if (s <= pen) {
      near = min(near, sdSeg(here, last * asp, point * asp));
      tip = point;
    }
    last = point;
  }
  let stroke = 1.0 - step(0.012, near);
  let under = sat((cycle - 0.62) * 6.0);
  let rule = (1.0 - step(0.5 / g.count.y, abs(y - 0.3))) * step(0.16, x) * step(x, 0.16 + 0.68 * under);
  let glow = (1.0 - step(0.025, length(here - tip * asp))) * (1.0 - step(0.999, pen));
  let fade = 1.0 - smoothstep(0.92, 1.0, cycle);
  let on = max(stroke, rule) * fade;
  let amount = max(on * 0.88, glow);
  let tone = max(on * 0.6, glow);
  return emit(g, length(g.local) - mix(0.7, 2.2, max(on, glow)), ramp(tone), amount);
`,
}
