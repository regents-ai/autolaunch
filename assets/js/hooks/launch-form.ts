import type { Hook } from "phoenix_live_view"

interface EthereumProvider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>
}

declare global {
  interface Window {
    ethereum?: EthereumProvider
  }
}

function buildSiwaMessage(args: {
  walletAddress: string
  chainId: number
  nonce: string
  issuedAt: string
}): string {
  const domain = window.location.host
  const uri = `${window.location.origin}/`

  return [
    `${domain} wants you to sign in with your Ethereum account:`,
    args.walletAddress,
    "",
    "Authorize Regent autolaunch launch request.",
    "",
    `URI: ${uri}`,
    "Version: 1",
    `Chain ID: ${args.chainId}`,
    `Nonce: ${args.nonce}`,
    `Issued At: ${args.issuedAt}`,
  ].join("\n")
}

function readForm(root: HTMLElement): Record<string, string | boolean> {
  const fields = Array.from(root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>("input[name], textarea[name]"))

  return fields.reduce<Record<string, string | boolean>>((acc, field) => {
    const match = /^launch\[(.+)\]$/.exec(field.name)
    if (!match) return acc

    const key = match[1]
    if (field instanceof HTMLInputElement && field.type === "checkbox") {
      acc[key] = field.checked
    } else {
      acc[key] = field.value
    }
    return acc
  }, {})
}

function parseLaunchChainId(value: string | undefined): number | null {
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed === 1 ? parsed : null
}

export const LaunchForm: Hook = {
  mounted() {
    const submitButton = this.el.querySelector<HTMLElement>("[data-launch-submit]")
    if (!submitButton) return

    submitButton.addEventListener("click", async () => {
      if (submitButton.hasAttribute("disabled")) return

      const ethereum = window.ethereum
      if (!ethereum) {
        this.pushEvent("launch_error", { message: "Connect an EVM wallet in this browser first." })
        return
      }

      this.pushEvent("launch_submitting", {})

      try {
        const accountResult = await ethereum.request({ method: "eth_requestAccounts" })
        const walletAddress = Array.isArray(accountResult) ? String(accountResult[0] || "") : ""
        if (!walletAddress) throw new Error("Wallet connection was cancelled.")

        const chainId = parseLaunchChainId(submitButton.dataset.launchChainId)
        if (!chainId) {
          throw new Error("Launch network is unavailable. Refresh and try again.")
        }
        const nonceEndpoint = submitButton.dataset.nonceEndpoint || "/v1/agent/siwa/nonce"
        const launchEndpoint = submitButton.dataset.launchEndpoint || "/api/launch/jobs"
        const issuedAt = new Date().toISOString()

        const nonceResponse = await fetch(nonceEndpoint, {
          method: "POST",
          headers: {
            accept: "application/json",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            walletAddress,
            chainId,
            audience: "autolaunch",
          }),
        })

        const noncePayload = (await nonceResponse.json()) as { nonce?: string; error?: { message?: string } }
        if (!nonceResponse.ok || !noncePayload.nonce) {
          throw new Error(noncePayload.error?.message || "Unable to issue SIWA nonce.")
        }

        const message = buildSiwaMessage({
          walletAddress,
          chainId,
          nonce: noncePayload.nonce,
          issuedAt,
        })

        const signature = (await ethereum.request({
          method: "personal_sign",
          params: [message, walletAddress],
        })) as string

        const csrfToken =
          document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() || ""

        const form = readForm(this.el)
        const response = await fetch(launchEndpoint, {
          method: "POST",
          headers: {
            accept: "application/json",
            "content-type": "application/json",
            ...(csrfToken ? { "x-csrf-token": csrfToken } : {}),
          },
          credentials: "same-origin",
          body: JSON.stringify({
            ...form,
            wallet_address: walletAddress,
            nonce: noncePayload.nonce,
            message,
            signature,
            issued_at: issuedAt,
          }),
        })

        const payload = (await response.json()) as {
          job_id?: string
          error?: { message?: string }
        }

        if (!response.ok || !payload.job_id) {
          throw new Error(payload.error?.message || "Failed to queue launch job.")
        }

        this.pushEvent("launch_queued", { job_id: payload.job_id })
      } catch (error) {
        const message = error instanceof Error ? error.message : "Launch request failed."
        this.pushEvent("launch_error", { message })
      }
    })
  },
}
