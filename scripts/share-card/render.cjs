// Draws the pictures autolaunch.sh shows when an address is shared, into
// platform/priv/static/images: home.html as og-image.png and how-it-works.html as
// og-how-it-works.png. Fails when a word sits
// where X hides or covers it: past x 640 (X's narrow view keeps the left ~660
// px) or in the bottom-left corner where X lays the page title.
//
//   node scripts/share-card/render.cjs
const path = require('path');
const { chromium } = require(path.join(__dirname, '../../platform/node_modules/playwright'));

const pictures = [
  ['home.html', 'og-image.png'],
  ['how-it-works.html', 'og-how-it-works.png'],
];

async function draw(browser, sourceName, targetName) {
  const source = path.join(__dirname, sourceName);
  const target = path.join(__dirname, '../../platform/priv/static/images', targetName);
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(`file://${source}`);
  await page.evaluate(() => document.fonts.ready);

  const report = await page.evaluate(() => {
    const fonts = [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family);
    const words = ['.where', '.eyebrow', 'h1', '.lede'].filter((selector) => document.querySelector(selector)).map((selector) => {
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
  if (!report.fonts.includes('Geist Serif')) problems.push('font Geist Serif not loaded');
  for (const w of report.words) {
    if (w.right > 640) problems.push(`${w.selector} reaches x=${w.right.toFixed(0)}, past X's narrow view`);
    if (w.left < 760 && w.bottom > 520) problems.push(`${w.selector} sits under X's title`);
  }
  if (report.overflow.length) problems.push(`a product panel overflows: ${report.overflow.join(', ')}`);

  if (problems.length) {
    console.error(`${sourceName}: ${problems.join('\n')}`);
    await browser.close();
    process.exit(1);
  }

  await page.screenshot({ path: target });
  await page.close();
  console.log(`wrote ${path.relative(process.cwd(), target)}`);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  for (const [sourceName, targetName] of pictures) await draw(browser, sourceName, targetName);
  await browser.close();
})();
