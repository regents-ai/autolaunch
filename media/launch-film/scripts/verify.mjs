import {createHash} from 'node:crypto';
import {lstat, readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(await readFile(path.join(root, 'assets-manifest.json'), 'utf8'));
let checked = 0;
for (const [relative, expected] of Object.entries(manifest)) {
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error('Manifest path outside project');
  if ((await lstat(file)).isSymbolicLink()) throw new Error(`Unexpected symlink: ${relative}`);
  const actual = createHash('sha256').update(await readFile(file)).digest('hex');
  if (actual !== expected) throw new Error(`Asset hash mismatch: ${relative}`);
  checked += 1;
}
console.log(`Verified ${checked} included media files.`);
