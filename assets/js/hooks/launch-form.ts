import type { Hook } from "phoenix_live_view"

interface EthereumProvider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>
}

type LaunchFormElement = HTMLElement & {
  _launchFormCleanup?: () => void
  _launchFormMounted?: boolean
}

declare global {
  interface Window {
    ethereum?: EthereumProvider
  }
}

export function buildSiwaMessage(args: {
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

export function readCsrfToken(): string {
  return document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() ?? ""
}

export function firstRequestedAccount(result: unknown): string {
  return Array.isArray(result) ? String(result[0] ?? "") : ""
}

export function launchEndpoints(dataset: DOMStringMap): {
  nonceEndpoint: string
  launchEndpoint: string
} {
  return {
    nonceEndpoint: dataset.nonceEndpoint?.trim() || "/v1/agent/siwa/nonce",
    launchEndpoint: dataset.launchEndpoint?.trim() || "/api/launch/jobs",
  }
}

export function buildLaunchRequestBody(args: {
  form: Record<string, string | boolean>
  walletAddress: string
  nonce: string
  message: string
  signature: string
  issuedAt: string
}): Record<string, string | boolean> {
  return {
    ...args.form,
    wallet_address: args.walletAddress,
    nonce: args.nonce,
    message: args.message,
    signature: args.signature,
    issued_at: args.issuedAt,
  }
}

export function readForm(root: HTMLElement): Record<string, string | boolean> {
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

export function parseLaunchChainId(value: string | undefined): number | null {
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed === 11_155_111 ? parsed : null
}

export const LaunchForm: Hook = {
  mounted() {
    const root = this.el as LaunchFormElement
    root._launchFormCleanup?.()
    root._launchFormMounted = true

    const submitButton = root.querySelector<HTMLElement>("[data-launch-submit]")
    if (!submitButton) return

    const onClick = async () => {
      if (submitButton.hasAttribute("disabled")) return

      const ethereum = window.ethereum
      if (!ethereum) {
        this.pushEvent("launch_error", { message: "Connect an EVM wallet in this browser first." })
        return
      }

      this.pushEvent("launch_submitting", {})

      try {
        const walletAddress = firstRequestedAccount(await ethereum.request({ method: "eth_requestAccounts" }))
        if (!walletAddress) throw new Error("Wallet connection was cancelled.")

        const { launchChainId } = submitButton.dataset
        const { nonceEndpoint, launchEndpoint } = launchEndpoints(submitButton.dataset)
        const chainId = parseLaunchChainId(launchChainId)
        if (!chainId) {
          throw new Error("Launch network is unavailable. Refresh and try again.")
        }
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

        const csrfToken = readCsrfToken()
        const form = readForm(this.el)
        const response = await fetch(launchEndpoint, {
          method: "POST",
          headers: {
            accept: "application/json",
            "content-type": "application/json",
            ...(csrfToken ? { "x-csrf-token": csrfToken } : {}),
          },
          credentials: "same-origin",
          body: JSON.stringify(
            buildLaunchRequestBody({
              form,
              walletAddress,
              nonce: noncePayload.nonce,
              message,
              signature,
              issuedAt,
            }),
          ),
        })

        const payload = (await response.json()) as {
          job_id?: string
          error?: { message?: string }
        }

        if (!response.ok || !payload.job_id) {
          throw new Error(payload.error?.message || "Failed to queue launch job.")
        }

        if (root._launchFormMounted) {
          this.pushEvent("launch_queued", { job_id: payload.job_id })
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Launch request failed."
        if (root._launchFormMounted) {
          this.pushEvent("launch_error", { message })
        }
      }
    }

    submitButton.addEventListener("click", onClick)
    root._launchFormCleanup = () => {
      root._launchFormMounted = false
      submitButton.removeEventListener("click", onClick)
    }
  },

  destroyed() {
    const root = this.el as LaunchFormElement
    root._launchFormCleanup?.()
  },
}
