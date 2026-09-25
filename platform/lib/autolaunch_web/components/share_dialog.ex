defmodule AutolaunchWeb.Components.ShareDialog do
  @moduledoc """
  A "Share on X" button and the window it opens over the page: the post,
  which the reader can edit, the picture X will show with it, and a button
  that opens X's own composer with the post filled in. Nothing is ever
  posted for the reader.

  The window is the browser's own modal dialog, so the page behind it cannot
  be reached while it is open and focus goes back to the button once it
  closes. Escape, a click outside it or its Close button close it, and so does
  opening X. Its post lives in the browser: edits go straight into the X
  address without a round trip to the server.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :message, :string, required: true, doc: "the post the window starts with"
  attr :image, :string, required: true, doc: "the address of the page's share picture"
  attr :rest, :global, doc: "for the opening button, such as `phx-click` to read an X account"

  slot :account, doc: "who the reader is on X, above the post"

  def share_dialog(assigns) do
    ~H"""
    <div id={@id} class="share-x" phx-hook=".ShareDialog">
      <Regent.Primitives.button
        type="button"
        variant="secondary"
        aria-haspopup="dialog"
        data-share-open
        {@rest}
      >
        Share on X
      </Regent.Primitives.button>
      <dialog
        id={"#{@id}-dialog"}
        class="share-x__dialog"
        aria-labelledby={"#{@id}-title"}
        phx-mounted={JS.ignore_attributes(["open", "data-closing"])}
      >
        <div class="share-x__box">
          <h2 id={"#{@id}-title"} class="share-x__title">Share on X</h2>
          {render_slot(@account)}
          <img
            class="share-x__preview"
            src={@image}
            alt="The picture X shows with your post"
            width="1200"
            height="630"
            loading="lazy"
          />
          <label for={"#{@id}-message"} class="share-x__label">Your post</label>
          <textarea id={"#{@id}-message"} class="share-x__message" rows="3" data-share-message>{@message}</textarea>
          <div class="share-x__actions">
            <a
              href={intent(@message)}
              target="_blank"
              rel="noopener noreferrer"
              class="rg-button rg-button--primary"
              autofocus
              data-share-post
            >
              <span class="rg-button__label">Open X to share</span>
            </a>
            <button type="button" class="rg-button rg-button--secondary" data-share-close>
              <span class="rg-button__label">Close</span>
            </button>
          </div>
          <p class="share-x__note">
            X opens with your post ready. Nothing is posted until you post it there.
          </p>
        </div>
      </dialog>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ShareDialog">
      export default {
        mounted() {
          const dialog = this.el.querySelector("dialog")
          const message = dialog.querySelector("[data-share-message]")
          const post = dialog.querySelector("[data-share-post]")

          // The window plays its closing motion, then closes; with no motion
          // running it closes at once. Opening X closes it at once, as the
          // reader is leaving for X's tab.
          const close = () => {
            if (!dialog.open || "closing" in dialog.dataset) return
            dialog.dataset.closing = ""
            Promise.allSettled(dialog.getAnimations({subtree: true}).map((motion) => motion.finished)).then(() => {
              delete dialog.dataset.closing
              dialog.close()
            })
          }

          this.el.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-open]")) dialog.showModal()
          })
          dialog.addEventListener("cancel", (event) => {
            event.preventDefault()
            close()
          })
          dialog.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-post]")) dialog.close()
            else if (event.target === dialog || event.target.closest("[data-share-close]")) close()
          })
          message.addEventListener("input", () => {
            post.href = "https://x.com/intent/post?" + new URLSearchParams({text: message.value})
          })
        }
      }
    </script>
    """
  end

  defp intent(message), do: "https://x.com/intent/post?" <> URI.encode_query(%{text: message})
end
