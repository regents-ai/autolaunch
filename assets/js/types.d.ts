declare module "phoenix" {
  export const Socket: unknown
}

declare module "phoenix_live_view" {
  // The exact surface this application uses from phoenix_live_view.
  export class LiveSocket {
    constructor(path: string, socket: unknown, options: Record<string, unknown>)
    connect(): void
  }
}

declare module "phoenix-colocated/autolaunch" {
  export const hooks: Record<string, Record<string, (...args: unknown[]) => unknown>>
}

declare module "*.css"

declare module "node:fs" {
  export function readFileSync(path: URL): Uint8Array
}

declare module "node:zlib" {
  export function gzipSync(input: Uint8Array): Uint8Array
}

interface Window {
  liveSocket: import("phoenix_live_view").LiveSocket
}
