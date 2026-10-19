defmodule AutolaunchWeb.Components.ShareDialog do
  @moduledoc """
  A share button ("Share on X" unless a page names it otherwise) and the
  window it opens over the page: the post,
  which the reader can edit, the picture X will show with it, and a button
  that opens X's own composer with the post filled in. Nothing is ever
  posted for the reader.

  Given a `video`, the window also offers it: the video is fetched as the
  window opens, and "Share video" hands it to the phone's share sheet, or
  saves it on a computer, where the post is shared from X's own composer.
  A video that cannot be had says why in one plain line: the site's own words
  for what went wrong, or that the site could not reach its records.

  The window is the browser's own modal dialog, so the page behind it cannot
  be reached while it is open and focus goes back to the button once it
  closes. Escape, a click outside it or its Close button close it, and so does
  opening X. Its post lives in the browser: edits go straight into the X
  address without a round trip to the server.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :message, :string, required: true, doc: "the post the window starts with"
  attr :image, :string, required: true, doc: "the address of the page's share picture"
  attr :video, :string, default: nil, doc: "the address of a share video, or nil for none"
  attr :video_name, :string, default: "autolaunch.mp4", doc: "the name the video is saved under"

  attr :video_everyone, :string,
    default: nil,
    doc:
      "for a person's own video, the launch's video for everyone, offered once they have made their videos for the day"

  attr :label, :string, default: "Share on X", doc: "the opening button's words"
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
        {@label}
      </Regent.Primitives.button>
      <dialog
        id={"#{@id}-dialog"}
        class="share-x__dialog"
        aria-labelledby={"#{@id}-title"}
        {AutolaunchWeb.Motion.panel("sheet", ["open"])}
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
            <button
              :if={@video}
              type="button"
              class="rg-button rg-button--secondary"
              data-share-video={@video}
              data-share-video-everyone={@video_everyone}
              data-share-video-name={@video_name}
              disabled
            >
              <span class="rg-button__label" data-share-video-label>Preparing your video…</span>
            </button>
            <button type="button" class="rg-button rg-button--secondary" data-share-close>
              <span class="rg-button__label">Close</span>
            </button>
          </div>
          <p :if={@video} class="share-x__note" role="status" data-share-video-status hidden></p>
          <p :if={@video} class="share-x__note" data-share-video-note hidden>
            Your video couldn't be made just now. Try again in a moment.
          </p>
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
          const video = dialog.querySelector("[data-share-video]")
          const status = dialog.querySelector("[data-share-video-status]")
          const note = dialog.querySelector("[data-share-video-note]")
          const unmade = note && note.textContent.trim()
          let address = video && video.dataset.shareVideo
          let file = null
          let loading = null

          const say = (words) => {
            status.textContent = words
            status.hidden = !words
          }

          // The plain line for a video that cannot be had: the site's own words
          // for what went wrong, or that the site could not reach its records.
          // Anything else, such as a dropped connection, keeps the window's own
          // line.
          class Unanswered extends Error {}
          const unanswered = async (response) => {
            if (response.status === 503)
              return "The site couldn't reach its records just now. Try again in a moment."
            const answer = await response.json().catch(() => ({}))
            return answer.message || unmade
          }

          // Asks for the video until it is made. While it waits in line the
          // answer says how many videos are ahead of it; a person who has
          // made their videos for the day gets the launch's video instead.
          const ask = (until) =>
            fetch(address, {credentials: "same-origin"}).then(async (response) => {
              if (response.status === 200) return response.blob()

              if (response.status === 202 && Date.now() < until) {
                const {ahead} = await response.json()
                if (!video.dataset.limited)
                  say(ahead > 0 ? `${ahead} ${ahead === 1 ? "video" : "videos"} ahead of yours` : "Making your video now")
                await new Promise((resolve) => setTimeout(resolve, 2000))
                return ask(until)
              }

              if (response.status === 429 && video.dataset.shareVideoEveryone) {
                const {daily} = await response.json()
                address = video.dataset.shareVideoEveryone
                video.dataset.limited = "true"
                say(`You've made your ${daily} videos for today, so this is the video everyone sees.`)
                return ask(until)
              }

              throw new Unanswered(await unanswered(response))
            })

          // The video is fetched once the window opens, so it is ready to hand
          // over the moment it is asked for.
          const prepare = () => {
            if (!video || file || loading) return
            const label = video.querySelector("[data-share-video-label]")
            video.disabled = true
            label.textContent = "Preparing your video…"
            note.hidden = true
            loading = ask(Date.now() + 5 * 60 * 1000)
              .then((blob) => {
                if (!video.dataset.limited) say("")
                file = new File([blob], video.dataset.shareVideoName, {type: "video/mp4"})
                label.textContent = "Share video"
              })
              .catch((error) => {
                label.textContent = "Try the video again"
                if (!video.dataset.limited) say("")
                note.textContent = error instanceof Unanswered ? error.message : unmade
                note.hidden = false
              })
              .finally(() => {
                loading = null
                video.disabled = false
              })
          }

          // A phone hands the video to its share sheet; a computer saves it.
          const shareVideo = () => {
            if (!file) return prepare()
            const phone = window.matchMedia("(pointer: coarse)").matches
            if (phone && navigator.canShare && navigator.canShare({files: [file]})) {
              navigator.share({files: [file], text: message.value}).catch(() => {})
            } else {
              const link = document.createElement("a")
              link.href = URL.createObjectURL(file)
              link.download = file.name
              link.click()
              setTimeout(() => URL.revokeObjectURL(link.href), 1000)
            }
          }

          this.el.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-open]")) {
              dialog.showModal()
              prepare()
            }
          })
          if (video) video.addEventListener("click", shareVideo)
          dialog.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-post], [data-share-close]") || event.target === dialog) dialog.close()
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
