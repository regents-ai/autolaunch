import {parseArgs} from "node:util";

export class UsageError extends Error {}

export function argumentsFor(argv, commands) {
  const options = {
    json: {type: "boolean"}, help: {type: "boolean", short: "h"},
    version: {type: "boolean"}, "base-url": {type: "string"}, "timeout-ms": {type: "string"},
  };
  for (const command of commands) for (const flag of command.flags) options[flag] = {type: "string"};
  let parsed;
  try { parsed = parseArgs({args: argv, options, allowPositionals: true, strict: true, tokens: true}); }
  catch { throw new UsageError("Invalid arguments. Use --help for supported commands and flags."); }
  const seen = new Set();
  for (const token of parsed.tokens) {
    if (token.kind !== "option") continue;
    if (seen.has(token.name)) throw new UsageError(`Use --${token.name} only once.`);
    seen.add(token.name);
    if (typeof token.value === "string" && token.value.length === 0) {
      throw new UsageError(`Provide a value for --${token.name}.`);
    }
  }
  return parsed;
}

export function selectCommand(positionals, commands) {
  return commands.find(command => {
    const words = command.command.split(" ");
    return words.length === positionals.length && words.every((word, i) => word.startsWith("<") || word === positionals[i]);
  });
}

export function pathSegment(value) {
  if (!value || value === "." || value === "..") throw new UsageError("Provide a record identifier, not a dot-only path.");
  return encodeURIComponent(value);
}

export function query(path, values) {
  const search = new URLSearchParams(Object.entries(values).filter(([, value]) => value !== undefined));
  return search.size ? `${path}?${search}` : path;
}

export function required(values, flag) {
  const value = values[flag];
  if (typeof value !== "string" || !value.length) throw new UsageError(`Provide --${flag}.`);
  return value;
}

function origin(value) {
  let url;
  try { url = new URL(value); } catch { throw new UsageError("--base-url must be an HTTP origin."); }
  const loopback = ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) ||
      url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new UsageError("Use an HTTPS origin with no credentials, path, query or fragment; HTTP is allowed only for loopback fixtures.");
  }
  return url.origin;
}

async function request(base, target, timeoutMs) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  const timeout = AbortSignal.timeout(timeoutMs);
  const signal = AbortSignal.any([controller.signal, timeout]);
  process.once("SIGINT", interrupt);
  process.once("SIGTERM", interrupt);
  try {
    const response = await fetch(new URL(target.path, base), {
      method: target.body === undefined ? "GET" : "POST",
      headers: {accept: "application/json", ...(target.body === undefined ? {} : {"content-type": "application/json"})},
      body: target.body === undefined ? undefined : JSON.stringify(target.body),
      credentials: "omit", redirect: "error", cache: "no-store", signal,
    });
    // Never shorten domain values, signed cursors or evidence to fit a display budget.
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); }
    catch {
      return {ok: false, status: response.status, error: {code: "invalid_response", message: "The API did not return JSON."},
        body_text: text, content_type: response.headers.get("content-type"),
        ...(response.headers.has("retry-after") ? {retry_after: response.headers.get("retry-after")} : {})};
    }
    return {ok: response.ok, status: response.status, body,
      ...(response.headers.has("retry-after") ? {retry_after: response.headers.get("retry-after")} : {})};
  } catch {
    const code = controller.signal.aborted ? "aborted" : timeout.aborted ? "timeout" : "network_error";
    return {ok: false, error: {code, message: code === "network_error"
      ? "The API could not be reached or refused a direct request. Redirects are not followed."
      : "The public request was canceled. It was not retried."}};
  } finally {
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", interrupt);
  }
}

export async function run({product, version, defaultOrigin, commands, notes, argv = process.argv.slice(2)}) {
  try {
    const {values, positionals} = argumentsFor(argv, commands);
    if (values.version) return {product, version};
    if (positionals.join(" ") === "commands list") {
      if (Object.keys(values).some(key => key !== "json")) throw new UsageError("commands list takes only --json.");
      return {product, version, commands: commands.map(({request: _request, ...contract}) => contract), notes};
    }
    const command = selectCommand(positionals, commands);
    if (values.help || positionals.join(" ") === "help" || positionals.length === 0) {
      const help = {product, version, commands: (command ? [command] : commands).map(({request: _request, ...contract}) => contract), notes};
      if (values.json) return help;
      process.stdout.write(`${product} ${version}\n\n` + help.commands.map(c => `  ${product} ${c.command}${c.flags.length ? "  " + c.flags.map(f => (c.required_flags?.includes(f) ? "" : "[") + "--" + f + " <value>" + (c.required_flags?.includes(f) ? "" : "]")).join(" ") : ""}\n    ${c.description}`).join("\n") +
        `\n\n  ${product} commands list --json\n  --base-url <origin>  --timeout-ms <milliseconds>  --json  --help  --version\n\n` + notes.join("\n") + "\n");
      return undefined;
    }
    if (!command) throw new UsageError("Unknown command. Use --help for supported commands.");
    for (const key of Object.keys(values)) {
      if (!["json", "base-url", "timeout-ms", ...command.flags].includes(key)) throw new UsageError(`--${key} is not supported by ${command.command}.`);
    }
    const timeoutMs = values["timeout-ms"] === undefined ? 30000 : Number(values["timeout-ms"]);
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300000) throw new UsageError("--timeout-ms must be an integer from 1 to 300000.");
    const base = origin(values["base-url"] ?? process.env[`${product.toUpperCase()}_BASE_URL`] ?? defaultOrigin);
    const target = command.request(positionals, values);
    const result = await request(base, target, timeoutMs);
    if (!result.ok) process.exitCode = result.error?.code === "aborted" ? 130 : 1;
    return result;
  } catch (error) {
    process.exitCode = error instanceof UsageError ? 2 : 1;
    return {ok: false, error: {code: error instanceof UsageError ? "invalid_input" : "internal_error",
      message: error instanceof UsageError ? error.message : "The command could not be completed."}};
  }
}
