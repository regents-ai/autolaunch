// Draws home.html into platform/priv/static/images/og-image.png, the picture
// autolaunch.sh shows when its address is shared, and fails when a word sits
// where X hides or covers it: past x 640 (X's narrow view keeps the left ~660
// px) or in the bottom-left corner where X lays the page title.
//
//   node scripts/share-card/render.cjs
const path = require('path');
const { chromium } = require(path.join(__dirname, '../../platform/node_modules/playwright'));

const source = path.join(__dirname, 'home.html');
const target = path.join(__dirname, '../../platform/priv/static/images/og-image.png');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(`file://${source}`);
  await page.evaluate(() => document.fonts.ready);

  const report = await page.evaluate(() => {
    const fonts = [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family);
    const words = ['.where', '.eyebrow', 'h1'].map((selector) => {
      const range = document.createRange();
      range.selectNodeContents(document.querySelector(selector));
      const { left, right, bottom } = range.getBoundingClientRect();
      return { selector, left, right, bottom };
    });
    const overflow = [...document.querySelectorAll('.tile, .tile *')]
      .filter((e) => e.scrollWidth > e.clientWidth + 1 || (e.matches('.tile') && e.scrollHeight > e.clientHeight + 1))
      .map((e) => e.className || e.tagName);
    return { fonts, words, overflow };
  });

  const problems = [];
  for (const family of ['Geist Pixel', 'Geist', 'Geist Mono']) {
    if (!report.fonts.includes(family)) problems.push(`font ${family} not loaded`);
  }
  for (const w of report.words) {
    if (w.right > 640) problems.push(`${w.selector} reaches x=${w.right.toFixed(0)}, past X's narrow view`);
    if (w.left < 760 && w.bottom > 520) problems.push(`${w.selector} sits under X's title`);
  }
  if (report.overflow.length) problems.push(`a product panel overflows: ${report.overflow.join(', ')}`);

  if (problems.length) {
    console.error(problems.join('\n'));
    await browser.close();
    process.exit(1);
  }

  await page.screenshot({ path: target });
  await browser.close();
  console.log(`wrote ${path.relative(process.cwd(), target)}`);
})();
