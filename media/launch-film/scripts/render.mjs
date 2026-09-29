import {bundle} from '@remotion/bundler';
import {openBrowser, renderMedia, renderStill, selectComposition} from '@remotion/renderer';
import {mkdir, rename, rm} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'out');
const stills = process.argv.includes('--stills');
const silent = path.join(out, 'autolaunch.silent.partial.mp4');
const mux = path.join(out, 'autolaunch.mux.partial.mp4');
const master = path.join(out, 'autolaunch-launch.mp4');
const xDelivery = path.join(out, 'autolaunch-launch-x.mp4');
let browser;

try {
  if (!stills) execFileSync('ffmpeg', ['-version'], {stdio: 'ignore'});
  await mkdir(out, {recursive: true});
  const serveUrl = await bundle({
    entryPoint: path.join(root, 'src/index.tsx'),
    publicDir: path.join(root, 'public'),
    outDir: path.join(root, '.bundle'),
  });
  browser = await openBrowser('chrome', {
    browserExecutable: process.env.REMOTION_BROWSER_EXECUTABLE || undefined,
    logLevel: 'warn',
  });
  const composition = await selectComposition({
    serveUrl,
    id: 'AutolaunchLaunchFilm',
    puppeteerInstance: browser,
  });

  if (stills) {
    for (const frame of [30, 150, 198, 240, 330, 420, 510, 576, 690]) {
      await renderStill({
        serveUrl,
        composition,
        puppeteerInstance: browser,
        frame,
        output: path.join(out, `frame-${frame}.png`),
        imageFormat: 'png',
        logLevel: 'warn',
      });
    }
    console.log('Saved review frames to out/.');
  } else {
    let last = -1;
    await renderMedia({
      serveUrl,
      composition,
      puppeteerInstance: browser,
      outputLocation: silent,
      codec: 'h264',
      crf: 17,
      pixelFormat: 'yuv420p',
      muted: true,
      concurrency: 2,
      logLevel: 'warn',
      onProgress: ({progress}) => {
        const percent = Math.floor(progress * 10) * 10;
        if (percent !== last) {
          last = percent;
          console.log(`Render ${percent}%`);
        }
      },
    });
    execFileSync(
      'ffmpeg',
      [
        '-v', 'error', '-y', '-i', silent,
        '-i', path.join(root, 'public/assets/autolaunch-bed.m4a'),
        '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy', '-shortest',
        '-movflags', '+faststart', mux,
      ],
      {stdio: 'inherit'},
    );
    await rename(mux, master);
    execFileSync(
      'ffmpeg',
      [
        '-v', 'error', '-y', '-i', master,
        '-vf', 'scale=1200:1200:flags=lanczos,fps=30',
        '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', xDelivery,
      ],
      {stdio: 'inherit'},
    );
    console.log('Saved out/autolaunch-launch.mp4 and out/autolaunch-launch-x.mp4');
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close({silent: true});
  await rm(silent, {force: true});
  await rm(mux, {force: true});
}
