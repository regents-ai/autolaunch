// Private profile transport. The paired proof is accepted only through a pipe,
// held for one request, and never placed in argv, cookies, files or output.
export class ProfileInputError extends Error {}

export function profileTarget(operation, values = {}) {
  if (operation === "get") return {method: "GET", path: "/api/v1/profile"};
  if (operation === "sync") return {method: "POST", path: "/api/v1/profile/sync"};
  if (operation !== "update") throw new ProfileInputError("Unknown profile operation.");
  const body = {};
  if (values["display-name"] !== undefined) body.display_name = values["display-name"];
  if (values["wallet-address"] !== undefined) body.wallet_address = values["wallet-address"];
  if (values["clear-wallet"] !== undefined) {
    if (values["clear-wallet"] !== "true" || body.wallet_address !== undefined) throw new ProfileInputError("Use --clear-wallet true without --wallet-address.");
    body.wallet_address = null;
  }
  if (!Object.keys(body).length) throw new ProfileInputError("Provide --display-name, --wallet-address or --clear-wallet true.");
  if (body.display_name !== undefined && (typeof body.display_name !== "string" || Buffer.byteLength(body.display_name) > 320)) throw new ProfileInputError("Display name is too long.");
  if (body.wallet_address !== undefined && body.wallet_address !== null && !/^0x[a-fA-F0-9]{40}$/.test(body.wallet_address)) throw new ProfileInputError("Provide an Ethereum wallet address.");
  return {method: "PATCH", path: "/api/v1/profile", body};
}

export function readProfileProof(stream = process.stdin, timeoutMs = 30000) {
  if (stream.isTTY) return Promise.reject(new ProfileInputError("Pipe a paired Privy proof JSON object from your approved credential provider."));
  return new Promise((resolve, reject) => {
    let chunks = [], size = 0;
    const finish = (error, value) => {
      clearTimeout(timer);
      stream.removeListener("data", data);
      stream.removeListener("end", end);
      stream.removeListener("error", failed);
      stream.pause();
      chunks = [];
      if (error) reject(error); else resolve(value);
    };
    const failed = () => finish(new ProfileInputError("Could not read a paired Privy proof from stdin."));
    const data = chunk => {
      size += Buffer.byteLength(chunk);
      if (size > 70000) return failed();
      chunks.push(Buffer.from(chunk));
    };
    const end = () => {
      try {
        const pair = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (!pair || Array.isArray(pair) || Object.keys(pair).sort().join(",") !== "access,identity" ||
            ![pair.access, pair.identity].every(token => typeof token === "string" && token.length > 0 && token.length <= 32768 && /^[A-Za-z0-9_.-]+$/.test(token))) return failed();
        finish(null, pair);
      } catch { failed(); }
    };
    const timer = setTimeout(failed, timeoutMs);
    stream.on("data", data); stream.once("end", end); stream.once("error", failed);
    stream.resume();
  });
}

export async function requestProfile(base, target, timeoutMs = 30000) {
  // Validate destinations before consuming credentials. A caller must explicitly
  // opt into an alternate origin; product wrappers ignore public origin env vars.
  let url;
  try { url = new URL(base); } catch { throw new ProfileInputError("Provide a profile HTTPS origin or HTTP loopback fixture."); }
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) || url.username || url.password || url.pathname !== "/" || url.search || url.hash) throw new ProfileInputError("Provide a profile HTTPS origin or HTTP loopback fixture.");
  const pair = await readProfileProof(process.stdin, timeoutMs);
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  const timeout = AbortSignal.timeout(timeoutMs);
  let dispatched = false;
  process.once("SIGINT", interrupt); process.once("SIGTERM", interrupt);
  try {
    dispatched = true;
    const response = await fetch(new URL(target.path, url), {
      method: target.method,
      headers: {accept: "application/json", authorization: `Bearer ${pair.access}`, "privy-id-token": pair.identity,
        ...(target.body ? {"content-type": "application/json"} : {})},
      body: target.body ? JSON.stringify(target.body) : undefined,
      credentials: "omit", redirect: "error", cache: "no-store", signal: AbortSignal.any([controller.signal, timeout]),
    });
    // Fixed server schemas contain no proof. Reject any reflected proof, including
    // a proxy's error body; never include arbitrary response text in an error.
    const chunks = [];
    let bytes = 0;
    const reader = response.body?.getReader();
    if (!reader) throw new Error("invalid_response");
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 1000000) {
        await reader.cancel();
        throw new Error("invalid_response");
      }
      chunks.push(Buffer.from(value));
    }
    const text = Buffer.concat(chunks).toString("utf8");
    const body = JSON.parse(text);
    const normalized = JSON.stringify(body);
    if (normalized.includes(pair.access) || normalized.includes(pair.identity) || !body || Array.isArray(body) ||
        !(body.profile && typeof body.profile === "object" || body.error && typeof body.error.code === "string")) throw new Error("invalid_response");
    return {ok: response.ok, status: response.status, body};
  } catch {
    return {ok: false, status: null, error: {
      code: controller.signal.aborted ? "aborted" : timeout.aborted ? "timeout" : "profile_unavailable",
      outcome_unknown: dispatched && target.method !== "GET",
    }};
  } finally {
    process.removeListener("SIGINT", interrupt); process.removeListener("SIGTERM", interrupt);
  }
}
