type SwapDialogHook = {
  el: HTMLDialogElement
  pushEvent(event: string, payload: {token_id: string}): void
  cleanup?: () => void
}

// This hook owns only dialog lifetime and focus, never wallet or transaction state.
export const AutolaunchSwapDialog = {
  mounted(this: SwapDialogHook) {
    const opener = document.activeElement
    const tokenId = this.el.dataset.tokenId!
    let closed = false
    const restoreFocus = () => {
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus({preventScroll: true})
    }
    const onClose = () => {
      if (closed) return
      closed = true
      restoreFocus()
      this.pushEvent("close_trade", {token_id: tokenId})
    }
    const onCancel = (event: Event) => {
      event.preventDefault()
      this.el.close()
    }
    const onClick = (event: MouseEvent) => {
      const target = event.target
      if (target instanceof Element && target.closest("[data-close-swap]")) {
        this.el.close()
      } else if (target === this.el) {
        const box = this.el.getBoundingClientRect()
        if (event.clientX < box.left || event.clientX > box.right ||
            event.clientY < box.top || event.clientY > box.bottom) this.el.close()
      }
    }
    this.el.addEventListener("close", onClose)
    this.el.addEventListener("cancel", onCancel)
    this.el.addEventListener("click", onClick)
    this.el.showModal()
    this.el.querySelector<HTMLInputElement>('input[name="amount"]')?.focus({preventScroll: true})
    this.cleanup = () => {
      this.el.removeEventListener("close", onClose)
      this.el.removeEventListener("cancel", onCancel)
      this.el.removeEventListener("click", onClick)
      if (this.el.open) this.el.close()
      if (!closed) restoreFocus()
      closed = true
    }
  },
  destroyed(this: SwapDialogHook) { this.cleanup?.() },
}
