export const csrfMetaSelector = "meta[name='csrf-token']"

type MetaElement = {getAttribute: (name: string) => string | null}
type MetaSource = {querySelector: (selectors: string) => MetaElement | null}

// The socket handshake is accepted only with the token the server stamped into
// the document head, so a document without one has nothing to connect with.
export function browserCsrfToken(source: MetaSource): string {
  const token = source.querySelector(csrfMetaSelector)?.getAttribute("content")

  if (!token) {
    throw new Error("the document carries no csrf-token meta tag")
  }

  return token
}
