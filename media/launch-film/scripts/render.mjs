import {bundle} from '@remotion/bundler';
import {openBrowser, selectComposition, renderStill, renderMedia} from '@remotion/renderer';
import {mkdir} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'out/revision-4');
const master = path.join(out, 'autolaunch-master.mp4');
const delivery = path.join(out, 'autolaunch-x.mp4');
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const stills = process.argv.includes('--stills');
let browser;
try {
  await mkdir(out, {recursive: true});
  const serveUrl = await bundle({entryPoint: path.join(root, 'src/index.tsx'), publicDir: path.join(root, 'public'), outDir: path.join(root, '.bundle')});
  browser = await openBrowser('chrome', {browserExecutable: process.env.REMOTION_BROWSER_EXECUTABLE || (existsSync(chrome) ? chrome : undefined), logLevel: 'warn'});
  const composition = await selectComposition({serveUrl, id: 'Autolaunch', puppeteerInstance: browser});
  if (stills) {
    const frames = [150, 630, 720, 780, 900, 960, 1080];
    for (const frame of frames) {
      await renderStill({serveUrl, composition, puppeteerInstance: browser, frame, output: path.join(out, `frame-${String(frame).padStart(4, '0')}.png`), imageFormat: 'png', logLevel: 'warn'});
    }
    console.log('Rendered review frames.');
  } else {
    let last = -1;
    await renderMedia({serveUrl, composition, puppeteerInstance: browser, outputLocation: master, codec: 'h264', crf: 17, pixelFormat: 'yuv420p', concurrency: 2, logLevel: 'warn', onProgress: ({progress}) => {
      const percent = Math.floor(progress * 10) * 10;
      if (percent !== last) {last = percent; console.log(`Render ${percent}%`);}
    }});
    execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', master, '-vf', 'scale=1080:1080:flags=lanczos:in_range=full:out_range=limited,fps=30', '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', delivery], {stdio: 'inherit'});
    console.log('Rendered master and X delivery.');
  }
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close({silent: true});
}
