export function createScene(canvas, assetUrl) {
  const output = canvas.getContext('2d');
  const surface = document.createElement('canvas');
  surface.width = 1400;
  surface.height = 1400;
  const c = surface.getContext('2d');
  if (!c || !output) throw new Error('Canvas 2D context unavailable');

  const W = 768;
  const PLATINUM = '#E5E3D2';
  const CHARCOAL = '#161616';
  const TANGERINE = '#FF5B19';
  const POWDER = '#AECACD';
  const MUTED = '#6A695F';
  const logo = new Image();
  logo.src = assetUrl('autolaunch-mark.svg');

  const clamp = (value) => Math.max(0, Math.min(1, value));
  const lerp = (from, to, progress) => from + (to - from) * progress;
  const ease = (progress) => 1 - Math.pow(1 - clamp(progress), 3);
  const smooth = (progress) => {
    const p = clamp(progress);
    return p * p * (3 - 2 * p);
  };
  const step = (time, from, to) => ease((time - from) / (to - from));

  function text(value, x, y, size = 40, color = CHARCOAL, align = 'center', face = 'Sans', weight = 400) {
    c.font = `${weight} ${size}px "Geist ${face}", Arial, sans-serif`;
    c.textAlign = align;
    c.textBaseline = 'middle';
    c.fillStyle = color;
    c.fillText(value, x, y);
  }

  function line(x1, y1, x2, y2, color = CHARCOAL, width = 2) {
    c.beginPath();
    c.moveTo(x1, y1);
    c.lineTo(x2, y2);
    c.strokeStyle = color;
    c.lineWidth = width;
    c.lineCap = 'square';
    c.stroke();
  }

  function layer(x, y, scale, alpha, blur, draw) {
    c.save();
    c.translate(x, y);
    c.scale(scale, scale);
    c.globalAlpha *= clamp(alpha);
    if (blur > 0) c.filter = `blur(${blur}px)`;
    draw();
    c.restore();
  }

  function cutPath(x, y, width, height, cut = 12) {
    c.beginPath();
    c.moveTo(x + cut, y);
    c.lineTo(x + width, y);
    c.lineTo(x + width, y + height - cut);
    c.lineTo(x + width - cut, y + height);
    c.lineTo(x, y + height);
    c.lineTo(x, y + cut);
    c.closePath();
  }

  function cutPanel(x, y, width, height, fill, stroke = null, cut = 12) {
    cutPath(x, y, width, height, cut);
    c.fillStyle = fill;
    c.fill();
    if (stroke) {
      c.strokeStyle = stroke;
      c.lineWidth = 1;
      c.stroke();
    }
  }

  function grid(alpha = 0.12, color = CHARCOAL) {
    c.save();
    c.globalAlpha = alpha;
    c.strokeStyle = color;
    c.lineWidth = 0.7;
    for (let value = 0; value <= W; value += 48) {
      line(value, 0, value, W, color, 0.7);
      line(0, value, W, value, color, 0.7);
    }
    c.restore();
  }

  function pixelMark(x, y, size, color = TANGERINE) {
    const cells = [
      [0, 0], [2, 0], [4, 0],
      [0, 1], [1, 1], [2, 1], [3, 1], [4, 1],
      [0, 2], [1, 2], [2, 2], [3, 2], [4, 2],
    ];
    const unit = size / 5;
    c.fillStyle = color;
    for (const [column, row] of cells) c.fillRect(x + column * unit, y + row * unit, unit * 0.82, unit * 0.82);
  }

  function chipWidth(label) {
    c.font = '400 31px "Geist Mono", monospace';
    return Math.ceil(c.measureText(label).width) + 68;
  }

  function chip(label, x, y, alpha = 1) {
    layer(x, y, 1, alpha, 0, () => {
      const fills = {Auction: TANGERINE, Bid: POWDER, Graduate: PLATINUM};
      const inks = {Auction: '#000000', Bid: CHARCOAL, Graduate: CHARCOAL};
      const width = chipWidth(label);
      cutPanel(0, -27, width, 54, fills[label], CHARCOAL, 8);
      text(label === 'Auction' ? '01' : label === 'Bid' ? '02' : '03', 17, 1, 13, inks[label], 'left', 'Mono', 600);
      line(48, -17, 48, 17, inks[label], 1);
      text(label, 62, 1, 29, inks[label], 'left', 'Mono', 400);
    });
  }

  function searchBar(time) {
    const enter = step(time, 0.02, 0.52);
    const zoom = time < 1.8 ? lerp(0.72, 1.02, step(time, 0.5, 1.55)) : lerp(1.02, 1.2, step(time, 1.8, 2.75));
    const blur = (1 - enter) * 10 + Math.sin(clamp((time - 0.9) / 0.42) * Math.PI) * 3;
    layer(384, 384, zoom * enter, enter, blur, () => {
      cutPanel(-250, -42, 500, 84, CHARCOAL, TANGERINE, 12);
      pixelMark(-224, -15, 31, TANGERINE);
      line(-175, -22, -175, 22, '#4A4A45', 1);
      if (time < 1.95) {
        text('Autolaunch…', -149, 1, 26, '#A9A89C', 'left', 'Mono');
      } else {
        const phrase = 'launch a token';
        const count = Math.floor(step(time, 2.12, 2.76) * phrase.length);
        const typed = phrase.slice(0, count);
        text(typed, -149, 1, 29, PLATINUM, 'left', 'Sans');
        c.font = '400 29px "Geist Sans", Arial, sans-serif';
        const width = c.measureText(typed).width;
        line(-147 + width, -18, -147 + width, 20, TANGERINE, 2);
      }
      text('⌘ K', 186, 1, 17, '#A9A89C', 'left', 'Mono');
    });

    if (time < 1.24) {
      const progress = step(time, 0.12, 0.58);
      c.save();
      c.globalAlpha = 1 - step(time, 0.8, 1.24);
      c.fillStyle = TANGERINE;
      c.fillRect(174, 429, 420 * progress, 3);
      c.restore();
    }
  }

  function marketReveal(time) {
    const enter = step(time, 2.8, 3.14);
    const collapse = step(time, 3.58, 3.94);
    const shrink = step(time, 4.28, 4.62);
    const width = lerp(lerp(768, 250, collapse), 152, shrink);
    const height = lerp(lerp(70 + 698 * enter, 92, collapse), 48, shrink);
    const blur = 14 * Math.sin(clamp((time - 3.62) / 0.43) * Math.PI);

    layer(384, 384, 1, 1, blur, () => {
      cutPanel(-width / 2, -height / 2, width, height, TANGERINE, CHARCOAL, Math.min(16, height / 4));
      c.save();
      c.beginPath();
      cutPath(-width / 2, -height / 2, width, height, Math.min(16, height / 4));
      c.clip();
      c.globalAlpha = 0.17;
      for (let x = -width / 2; x < width / 2; x += 24) line(x, -height / 2, x + height, height / 2, CHARCOAL, 1);
      c.restore();
    });

    if (time < 3.75) {
      const exit = step(time, 3.42, 3.74);
      c.save();
      c.globalAlpha = 1 - exit;
      text('A MARKET', 384, 341 - exit * 22, 58, '#000000', 'center', 'Pixel Square');
      text('FINDS ITS PRICE', 384, 419 + exit * 22, 58, '#000000', 'center', 'Pixel Square');
      c.restore();
    } else if (time < 4.42) {
      const show = step(time, 3.78, 4.02) * (1 - step(time, 4.27, 4.4));
      layer(384, 384, 1, show, (1 - show) * 8, () => text('START AUCTION', 0, 0, 22, '#000000', 'center', 'Mono', 600));
    }
  }

  function journey(time) {
    if (time < 5.25) {
      const show = step(time, 4.68, 4.94);
      layer(384, 384, lerp(0.58, 1, show), show, (1 - show) * 7, () => text('from', 0, 0, 58, CHARCOAL, 'center', 'Pixel Square'));
      return;
    }

    if (time < 6.32) {
      const show = step(time, 5.25, 5.66);
      const zoom = lerp(1.75, 1, step(time, 5.97, 6.32));
      layer(384, 384, zoom, 1, Math.sin(clamp((time - 5.9) / 0.42) * Math.PI) * 2, () => {
        text('from a token', lerp(-650, -350, show), 0, 38, CHARCOAL, 'left', 'Sans');
        chip('Auction', -84, 0);
        text('to a market?', 141, 0, 38, CHARCOAL, 'left', 'Sans');
      });
      return;
    }

    const shift = step(time, 7.16, 7.66);
    const alpha = 1 - shift;
    layer(34, 384, 1, alpha, shift * 8, () => text('from a token', 0, 0, 38, CHARCOAL, 'left', 'Sans'));
    layer(525 + shift * 140, 384, 1, alpha, shift * 8, () => text('to a market?', 0, 0, 38, CHARCOAL, 'left', 'Sans'));

    const index = time < 6.68 ? 0 : time < 7.04 ? 1 : 2;
    const labels = ['Auction', 'Bid', 'Graduate'];
    const changeAt = index === 0 ? 6.32 : index === 1 ? 6.68 : 7.04;
    const enter = index === 0 ? 1 : step(time, changeAt, changeAt + 0.2);
    const x = lerp(300, 128, shift);
    if (index > 0) layer(x, 384 - 59 * enter, 1, (1 - enter) * 0.45, 6, () => chip(labels[index - 1], 0, 0));
    layer(x, 384 + (1 - enter) * 56, 1, 1, (1 - enter) * 5, () => chip(labels[index], 0, 0));
    if (index < 2) layer(x, 443, 1, 0.13, 5, () => chip(labels[index + 1], 0, 0));

    if (time > 7.3) {
      const show = step(time, 7.3, 7.72);
      layer(lerp(565, 128 + chipWidth('Graduate') + 12, show), 384, 1, show, (1 - show) * 9, () => {
        cutPanel(0, -27, 230, 54, CHARCOAL, TANGERINE, 8);
        const pulse = 0.55 + 0.45 * Math.sin(time * 12);
        c.fillStyle = TANGERINE;
        c.globalAlpha *= pulse;
        c.fillRect(20, -5, 10, 10);
        c.globalAlpha /= pulse;
        text('PRICE FOUND', 48, 1, 24, PLATINUM, 'left', 'Mono', 600);
      });
    }
  }

  function cardArtwork(index) {
    c.save();
    const inheritedAlpha = c.globalAlpha;
    c.beginPath();
    cutPath(0, 0, 240, 240, 14);
    c.clip();
    c.fillStyle = index === 0 ? TANGERINE : index === 1 ? POWDER : CHARCOAL;
    c.fillRect(0, 0, 240, 240);
    c.globalAlpha = inheritedAlpha * 0.22;
    for (let value = 0; value <= 240; value += 24) {
      line(value, 0, value, 240, index === 2 ? PLATINUM : CHARCOAL, 0.8);
      line(0, value, 240, value, index === 2 ? PLATINUM : CHARCOAL, 0.8);
    }
    c.globalAlpha = inheritedAlpha;

    if (index === 0) {
      pixelMark(44, 58, 152, '#000000');
      text('CREATE', 120, 203, 18, '#000000', 'center', 'Mono', 600);
    } else if (index === 1) {
      const heights = [130, 92, 155, 74, 118];
      for (let i = 0; i < heights.length; i += 1) {
        c.fillStyle = i === 2 ? TANGERINE : CHARCOAL;
        c.fillRect(35 + i * 36, 190 - heights[i], 17, heights[i]);
      }
      line(25, 190, 215, 190, CHARCOAL, 2);
      text('BID', 120, 214, 18, CHARCOAL, 'center', 'Mono', 600);
    } else {
      c.strokeStyle = TANGERINE;
      c.lineWidth = 5;
      c.beginPath();
      c.moveTo(24, 176);
      c.bezierCurveTo(82, 180, 80, 58, 136, 102);
      c.bezierCurveTo(176, 133, 180, 52, 220, 42);
      c.stroke();
      c.fillStyle = PLATINUM;
      c.fillRect(177, 39, 10, 10);
      text('GRADUATE', 120, 214, 18, PLATINUM, 'center', 'Mono', 600);
    }
    c.restore();
  }

  function journeyCard(index, x, y, width, alpha = 1, blur = 0) {
    layer(x, y, width / 240, alpha, blur, () => {
      const labels = ['Set the terms', 'Discover the price', 'Graduate onchain'];
      text(`0${index + 1}`, 0, -19, 12, MUTED, 'left', 'Mono', 600);
      text(labels[index], 30, -18, 13, MUTED, 'left', 'Sans', 600);
      cardArtwork(index);
    });
  }

  function cards(time) {
    const first = step(time, 8.27, 8.55);
    if (time < 8.71) {
      layer(80, 384, 0.82, 1 - step(time, 8.65, 8.72), 0, () => chip('Graduate', 0, 0));
      journeyCard(0, lerp(340, 276, first), lerp(328, 266, first), lerp(80, 236, first), first, (1 - first) * 8);
    } else if (time < 9.27) {
      const second = step(time, 8.71, 8.94);
      journeyCard(0, lerp(276, 214, second), lerp(266, 284, second), lerp(236, 196, second));
      journeyCard(1, lerp(570, 332, second), lerp(260, 254, second), lerp(200, 264, second), second, (1 - second) * 3);
    } else {
      const third = step(time, 9.27, 9.56);
      journeyCard(0, 214, 284, 196, 1 - third);
      journeyCard(1, lerp(332, 100, third), lerp(254, 282, third), lerp(264, 204, third));
      journeyCard(2, lerp(551, 400, third), 261, lerp(200, 247, third), third, (1 - third) * 4);
    }
  }

  function endCard(time) {
    const wipe = step(time, 9.99, 10.28);
    c.fillStyle = CHARCOAL;
    c.fillRect(0, 0, W, W);
    if (wipe < 1) {
      c.save();
      c.globalAlpha = 1 - wipe;
      c.fillStyle = PLATINUM;
      c.fillRect(0, 0, W, W);
      c.restore();
    }
    const fade = step(time, 10.03, 10.25);
    const badge = step(time, 10.68, 11.08);
    layer(330 - 25 * badge, 365 + 14 * (1 - fade), 1, fade, (1 - fade) * 10, () => text('Autolaunch', 0, 0, 58, PLATINUM, 'center', 'Pixel Square'));
    layer(536, 365, lerp(0.3, 1, badge), badge, (1 - badge) * 9, () => {
      c.shadowColor = 'rgba(255,91,25,.35)';
      c.shadowBlur = 28;
      cutPanel(-28, -28, 56, 56, '#000000', TANGERINE, 8);
      c.shadowBlur = 0;
      c.drawImage(logo, -22, -22, 44, 44);
    });
    const detail = step(time, 11.15, 11.55);
    layer(384, 430, 1, detail, (1 - detail) * 6, () => text('CREATE  ·  BID  ·  GRADUATE', 0, 0, 18, TANGERINE, 'center', 'Mono', 600));
    layer(384, 470, 1, detail, (1 - detail) * 6, () => text('AUTOLAUNCH.SH', 0, 0, 16, '#A9A89C', 'center', 'Mono', 400));
  }

  function drawAt(time) {
    c.save();
    c.setTransform(1400 / W, 0, 0, 1400 / W, 0, 0);
    c.fillStyle = PLATINUM;
    c.fillRect(0, 0, W, W);
    if (time < 2.8) searchBar(time);
    else if (time < 4.7) marketReveal(time);
    else if (time < 8.27) journey(time);
    else if (time < 10.02) cards(time);
    else endCard(time);
    c.restore();
  }

  function draw(time) {
    const moving =
      time < 0.6 ||
      (time > 0.9 && time < 1.4) ||
      (time > 1.9 && time < 2.88) ||
      (time > 3.4 && time < 4.7) ||
      (time > 5.25 && time < 6.4) ||
      (time > 6.65 && time < 7.8) ||
      (time > 8.26 && time < 9.6) ||
      (time > 10.01 && time < 10.3);
    const samples = moving ? 5 : 1;
    const shutter = time > 5.25 && time < 6.4 ? 0.046 : 0.028;
    output.save();
    output.setTransform(1, 0, 0, 1, 0, 0);
    output.fillStyle = PLATINUM;
    output.fillRect(0, 0, 1400, 1400);
    for (let index = 0; index < samples; index += 1) {
      const offset = samples === 1 ? 0 : (index / (samples - 1) - 0.5) * shutter;
      drawAt(Math.max(0, time + offset));
      output.globalAlpha = 1 / (index + 1);
      output.drawImage(surface, 0, 0);
    }
    output.restore();
  }

  const fonts = [
    new FontFace('Geist Sans', `url(${assetUrl('Geist-Regular.woff2')})`),
    new FontFace('Geist Sans', `url(${assetUrl('Geist-SemiBold.woff2')})`, {weight: '600'}),
    new FontFace('Geist Mono', `url(${assetUrl('GeistMono-Regular.woff2')})`),
    new FontFace('Geist Mono', `url(${assetUrl('GeistMono-SemiBold.woff2')})`, {weight: '600'}),
    new FontFace('Geist Pixel Square', `url(${assetUrl('GeistPixel-Square.woff2')})`),
  ];
  const ready = Promise.all([
    logo.decode(),
    ...fonts.map((font) => font.load().then((loaded) => document.fonts.add(loaded))),
  ]);

  return {ready, draw};
}
