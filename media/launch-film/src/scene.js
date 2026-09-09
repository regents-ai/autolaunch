// Motion adaptation of Tejashmakwana/astra-motion-recreation-remotion,
// d83832cace7e984c58dd805b668d2c41c15946fe; original direction @rajzmotion.
// Autolaunch copy, artwork, typography, sound and closing identity are separate.
export function createScene(canvas, assetUrl) {
  const output = canvas.getContext('2d');
  const surface = document.createElement('canvas');
  surface.width = surface.height = 1400;
  const c = surface.getContext('2d');
  if (!c || !output) throw new Error('Canvas 2D unavailable');
  const W = 768, PAPER = '#f3f1e9', INK = '#161616', ORANGE = '#FF5B19', PLATINUM = '#E5E3D2';
  const images = ['crown.svg'].map(name => {
    const image = new Image(); image.src = assetUrl(name); return image;
  });
  const clamp = v => Math.max(0, Math.min(1, v));
  const lerp = (a, b, p) => a + (b - a) * p;
  const ease = p => 1 - Math.pow(1 - clamp(p), 3);
  const step = (t, a, b) => ease((t - a) / (b - a));
  const smoother = (t, a, b) => {const p = clamp((t - a) / (b - a)); return p * p * (3 - 2 * p);};

  function text(value, x, y, size = 40, color = INK, align = 'center', weight = 400) {
    c.font = `${weight} ${size}px Geist, sans-serif`;
    c.fillStyle = color; c.textAlign = align; c.textBaseline = 'middle';
    c.fillText(value, x, y);
  }
  function width(value, size, weight = 400) {
    c.font = `${weight} ${size}px Geist, sans-serif`;
    return c.measureText(value).width;
  }
  function rect(x, y, w, h, radius, color) {
    c.beginPath(); c.roundRect(x, y, w, h, radius); c.fillStyle = color; c.fill();
  }
  function line(x, y, x2, y2, color = INK, thickness = 2) {
    c.beginPath(); c.moveTo(x, y); c.lineTo(x2, y2);
    c.strokeStyle = color; c.lineWidth = thickness; c.lineCap = 'round'; c.stroke();
  }
  function layer(x, y, scale, alpha, blur, fn) {
    if (alpha <= 0) return;
    c.save(); c.translate(x, y); c.scale(scale, scale);
    c.globalAlpha *= clamp(alpha);
    if (blur > 0.05) c.filter = `blur(${blur}px)`;
    fn(); c.restore();
  }
  function crown(x, y, size) {
    // Canonical 13-cell geometry and orange; charcoal matches the end-card ground.
    c.drawImage(images[0], x - size / 2, y - size / 2, size, size);
  }
  function shadow(amount = 1) {
    c.shadowColor = `rgba(34,29,20,${0.09 * amount})`;
    c.shadowBlur = 18; c.shadowOffsetY = 6;
  }

  function toolbar(t) {
    const p = step(t, 0.02, 0.55);
    const z = t < 1.8 ? lerp(0.74, 1.04, step(t, 0.5, 1.6)) : lerp(1.04, 1.2, step(t, 1.8, 2.8));
    layer(384, 384, z * p, p, (1 - p) * 9, () => {
      shadow();
      rect(-242, -33, 64, 66, 33, '#faf9f4');
      rect(-171, -33, 342, 66, 33, '#faf9f4');
      rect(178, -33, 64, 66, 33, '#faf9f4');
      c.shadowColor = 'transparent'; c.shadowOffsetY = 0;
      line(-205, -10, -215, 0); line(-215, 0, -205, 10);
      for (let i = 0; i < 3; i++) {c.beginPath(); c.arc(200 + i * 10, 0, 2, 0, Math.PI * 2); c.fillStyle = INK; c.fill();}
      // The orange/charcoal crown appears from the very first readable frame.
      crown(-140, 0, 36);
      if (t < 1.05) text('Autolaunch', -106, 0, 25, '#87867e', 'left');
      else {
        const phrase = 'a new way to launch';
        const n = Math.floor(clamp((t - 1.12) / 1.26) * phrase.length);
        const typed = phrase.slice(0, n);
        const size = Math.min(25, 227 / width(phrase, 25) * 25);
        text(typed, -106, 0, size, INK, 'left');
        const caret = -103 + width(typed, size);
        line(caret, -16, caret, 17, ORANGE, 2);
      }
      c.save(); c.translate(143, 0); c.rotate(-0.35);
      c.beginPath(); c.arc(0, 0, 8, -0.6, 4.8); c.lineWidth = 1.6; c.strokeStyle = '#8c8b83'; c.stroke();
      line(0, -10, 5, -7, '#8c8b83', 1.6); line(5, -7, 0, -3, '#8c8b83', 1.6); c.restore();
      const load = step(t, 0.15, 0.7) * (1 - step(t, 1.13, 1.48));
      layer(0, 43, 1, load, 0, () => {
        const gradient = c.createLinearGradient(-70, 0, 70, 0);
        gradient.addColorStop(0, '#b74716'); gradient.addColorStop(0.5, ORANGE); gradient.addColorStop(1, '#ecc4a6');
        rect(-70, 0, 140, 2.5, 2, gradient);
      });
    });
  }

  // Reference's full-frame soft-focus material reveal, then collapse into a pill.
  function material(w, h, t) {
    c.save(); c.beginPath(); c.rect(-w / 2, -h / 2, w, h); c.clip();
    c.fillStyle = '#c78857'; c.fillRect(-w / 2, -h / 2, w, h);
    c.filter = 'blur(65px)';
    const blobs = [
      [-280, -80, 220, '#ff6a21'], [40, 260, 170, '#513025'],
      [270, -250, 230, '#e3d1b2'], [-170, 350, 250, '#191818'],
      [80, -190, 175, '#ff510f'], [310, 180, 160, '#ae7d58'],
    ];
    for (const [x, y, radius, fill] of blobs) {
      c.beginPath(); c.fillStyle = fill;
      c.ellipse(x + 16 * Math.sin(t + x), y, radius, radius * 1.45, -0.5, 0, Math.PI * 2); c.fill();
    }
    c.restore();
  }
  function reveal(t) {
    const enter = step(t, 2.8, 3.12), collapse = step(t, 3.67, 4.05), shrink = step(t, 4.34, 4.68);
    const w = lerp(lerp(768, 244, collapse), 88, shrink);
    const h = lerp(lerp(70, 768, enter), 84, collapse) * lerp(1, 0.48, shrink);
    layer(384, 384, 1, 1 - step(t, 4.58, 4.74), 10 * Math.sin(clamp((t - 3.69) / 0.42) * Math.PI), () => material(w, h, t));
    if (t < 3.88) {
      const alpha = 1 - step(t, 3.56, 3.88);
      layer(384, 384, 1, alpha, (1 - alpha) * 10, () => {
        line(-384, -38, 384, -38, '#eac9af', 0.5);
        line(-384, 38, 384, 38, '#eac9af', 0.5);
        text('A new way to launch', 0, 0, 44, '#fffaf0');
      });
    } else {
      const alpha = step(t, 3.9, 4.1) * (1 - step(t, 4.31, 4.51));
      layer(384, 384, 1, alpha, (1 - alpha) * 6, () => text('Autolaunch', 0, 0, 30, '#fffaf0'));
    }
  }

  function productChip(label, x, y, alpha = 1, blurred = 0) {
    const w = width(label, 42) + 80;
    layer(x, y, 1, alpha, blurred, () => {
      rect(-w / 2, -36, w, 72, 10, label === 'Agent revenue' ? '#eadbcd' : '#dae3df');
      rect(-w / 2 + 10, -25, 49, 50, 7, INK);
      if (label === 'Agent revenue') {
        // Small split-path symbol, not a generic AI sparkle.
        line(-w / 2 + 23, 0, -w / 2 + 35, 0, ORANGE, 2);
        for (const dy of [-12, 12]) {line(-w / 2 + 35, 0, -w / 2 + 35, dy, ORANGE, 2); line(-w / 2 + 35, dy, -w / 2 + 47, dy, ORANGE, 2);}
      } else {
        for (const dx of [29, 41]) {c.beginPath(); c.arc(-w / 2 + dx, 0, 9, 0, Math.PI * 2); c.strokeStyle = dx === 29 ? '#aecacd' : ORANGE; c.lineWidth = 2; c.stroke();}
      }
      text(label, -w / 2 + 70, 0, 42, INK, 'left');
    });
  }
  function products(t) {
    const intro = step(t, 4.75, 5.14);
    const leave = step(t, 8.05, 8.5);
    layer(384, lerp(384, 304, step(t, 5.08, 5.46)), lerp(0.8, 1, intro), intro * (1 - leave), (1 - intro) * 9 + leave * 7, () => {
      text('Launch markets for', 0, 0, 45);
    });
    const entry = step(t, 5.3, 5.65), change = step(t, 6.65, 7.03);
    productChip('Agent revenue', 384, 412 - 72 * change, entry * (1 - change) * (1 - leave), (1 - entry) * 6 + change * 7);
    const stockAlpha = change * (1 - leave);
    productChip('Onchain stocks', 384, 412 + 72 * (1 - change), stockAlpha, (1 - change) * 7 + leave * 7);
  }

  function explanation(t) {
    const leave = step(t, 14.75, 15.25);
    const heading = step(t, 8.55, 9.0);
    layer(384, 242 + 18 * (1 - heading), 1, heading * (1 - leave), (1 - heading) * 7 + leave * 7, () => {
      text('Create Uniswap CCA', 0, 0, 39, INK, 'center', 500);
      text('auctions on Base for:', 0, 51, 39, INK, 'center', 500);
      line(-28, 91, 28, 91, ORANGE, 3);
    });

    // Keep the heading fixed; the second passage replaces the first in place.
    const passages = [
      {start: 9.1, lines: ['agents and x402 service.', 'Tokens are staked for', 'stablecoin revshare.']},
      {start: 12.0, lines: ['or pair your meme token', 'with any onchain stock', 'on Base']},
    ];
    for (const [index, passage] of passages.entries()) {
      const exit = index === 0 ? step(t, 11.75, 12.13) : leave;
      passage.lines.forEach((value, row) => {
        const enter = step(t, passage.start + row * 0.09, passage.start + row * 0.09 + 0.38);
        layer(384, 407 + row * 53 + 23 * (1 - enter) - 18 * exit, 1, enter * (1 - exit), (1 - enter) * 7 + exit * 7, () => text(value, 0, 0, 38));
      });
    }
  }

  function end(t) {
    const ground = smoother(t, 11.28, 11.7);
    c.save(); c.globalAlpha = ground; c.fillStyle = INK; c.fillRect(0, 0, W, W); c.restore();
    const mark = step(t, 11.55, 12.04);
    layer(384, 276, lerp(0.62, 1, mark), mark, (1 - mark) * 9, () => crown(0, 0, 166));
    const title = step(t, 11.84, 12.24);
    layer(384, 396 + 20 * (1 - title), 1, title, (1 - title) * 9, () => text('Autolaunch.', 0, 0, 68, PLATINUM, 'center', 500));
    const detail = step(t, 12.3, 12.72);
    layer(384, 478, 1, detail, (1 - detail) * 6, () => text('autolaunch.sh', 0, 0, 25, '#d0cfc3'));
    layer(384, 546, 1, detail, 0, () => {
      rect(-67, -15, 134, 30, 15, '#2a211b');
      text('Coming soon', 0, 0, 16, '#FF8B59');
    });
  }

  function drawAt(t) {
    c.save(); c.setTransform(1400 / W, 0, 0, 1400 / W, 0, 0);
    c.clearRect(0, 0, W, W); c.fillStyle = PAPER; c.fillRect(0, 0, W, W);
    if (t < 2.8) toolbar(t);
    else if (t < 4.75) reveal(t);
    else if (t < 8.55) products(t);
    else if (t < 15.42) explanation(t);
    if (t >= 15.0) end(t - 3.72);
    c.restore();
  }
  function draw(t) {
    const moving = t < 0.65 || (t > 1.9 && t < 2.8) || (t > 3.56 && t < 4.76) ||
      (t > 5.05 && t < 5.67) || (t > 6.64 && t < 7.05) ||
      (t > 8.05 && t < 9.7) || (t > 11.74 && t < 12.65) || (t > 14.74 && t < 16.1);
    const samples = moving ? 5 : 1;
    output.save(); output.setTransform(1, 0, 0, 1, 0, 0); output.clearRect(0, 0, 1400, 1400);
    for (let i = 0; i < samples; i++) {
      drawAt(Math.max(0, t + (samples === 1 ? 0 : (i / (samples - 1) - 0.5) * 0.032)));
      output.globalAlpha = 1 / (i + 1); output.drawImage(surface, 0, 0);
    }
    output.restore();
  }
  const fonts = [
    new FontFace('Geist', `url(${assetUrl('Geist-Regular.woff2')})`, {weight: '400'}),
    new FontFace('Geist', `url(${assetUrl('Geist-Medium.woff2')})`, {weight: '500'}),
  ];
  const ready = Promise.all([...images.map(image => image.decode()), ...fonts.map(font => font.load().then(loaded => document.fonts.add(loaded)))]);
  return {ready, draw};
}
