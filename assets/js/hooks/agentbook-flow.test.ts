import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { buildVerificationConstraints, parseSession } from "./agentbook-flow.ts"

describe("agentbook-flow hook", () => {
  it("parses a stored session payload", () => {
    const session = parseSession(
      JSON.stringify({
        session_id: "sess_1",
        status: "pending",
        frontend_request: {
          app_id: "app_test",
          action: "agentbook-registration",
          signal: "0xsignal",
          rp_context: { nonce: "n" },
        },
      }),
    )

    assert.equal(session?.session_id, "sess_1")
    assert.equal(session?.frontend_request?.signal, "0xsignal")
  })

  it("builds a v4-only proof-of-human constraint", () => {
    assert.deepEqual(buildVerificationConstraints("0xsignal"), {
      type: "proof_of_human",
      signal: "0xsignal",
    })
  })
})
