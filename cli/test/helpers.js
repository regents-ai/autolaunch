import {createServer} from "node:http";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {mkdtemp, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join, resolve} from "node:path";
export const exec = promisify(execFile);
export async function fixture(t) {
  const requests = [];
  let answer = {status: 200, body: {data: []}};
  const server = createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    requests.push({path: req.url, method: req.method, headers: req.headers, body: body ? JSON.parse(body) : undefined});
    if (answer.hang) return;
    res.writeHead(answer.status, {"content-type": answer.type ?? "application/json", ...answer.headers});
    res.end(answer.text ?? JSON.stringify(answer.body));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => { server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
  return {origin: `http://127.0.0.1:${server.address().port}`, requests, respond: value => { answer = value; }};
}
export async function invoke(bin, args, env = {}) {
  let result;
  try { result = {...await exec(process.execPath, [bin, ...args], {cwd: tmpdir(), env: {...process.env, ...env}, maxBuffer: 16 * 1024 * 1024, timeout: 10000}), code: 0}; }
  catch (error) { if (typeof error.code !== "number") throw error; result = error; }
  return {...result, json: JSON.parse(result.stdout)};
}
export async function installed(t, root, product) {
  const temp = await mkdtemp(join(tmpdir(), `${product}-packed-`));
  t.after(() => rm(temp, {recursive: true, force: true}));
  const packed = JSON.parse((await exec("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", temp], {cwd: root})).stdout)[0];
  await exec("npm", ["install", "--prefix", temp, "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false", join(temp, packed.filename)], {cwd: temp});
  return resolve(temp, "node_modules/.bin", product);
}
