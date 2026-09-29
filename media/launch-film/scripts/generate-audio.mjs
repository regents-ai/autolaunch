import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'public/assets/autolaunch-bed.m4a');

execFileSync(
  'ffmpeg',
  [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'sine=frequency=55:duration=12.55:sample_rate=48000',
    '-f', 'lavfi', '-i', 'sine=frequency=82.5:duration=12.55:sample_rate=48000',
    '-f', 'lavfi', '-i', 'sine=frequency=220:duration=12.55:sample_rate=48000',
    '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=12.55:sample_rate=48000:seed=831',
    '-filter_complex',
    "[0:a]volume=0.10[a0];[1:a]volume='0.04+0.035*sin(2*PI*t/2.4)':eval=frame[a1];[2:a]volume='if(lt(mod(t,1.2),0.09),0.09,0.006)':eval=frame,lowpass=f=1200[a2];[3:a]lowpass=f=420,volume=0.012[a3];[a0][a1][a2][a3]amix=inputs=4:normalize=0,volume=4,afade=t=in:st=0:d=0.5,afade=t=out:st=11.7:d=0.85,alimiter=limit=0.8[out]",
    '-map', '[out]', '-c:a', 'aac', '-b:a', '192k', output,
  ],
  {stdio: 'inherit'},
);

console.log(`Generated ${output}`);
