defmodule AutolaunchWeb.Components.ShareDialog do
  @moduledoc """
  A share button ("Share on X" unless a page names it otherwise) and the
  window it opens over the page: the post,
  which the reader can edit, the picture X will show with it, and a button
  that opens X's own composer with the post filled in. Nothing is ever
  posted for the reader.

  Given a `video`, the window also offers it: the video is fetched as the
  window opens and kept for as long as the page is open, so closing the window
  never loses it. "Share video" hands it to a phone's share sheet; on a
  computer "Download video" saves it, and the post is shared from X's own
  composer. A video that cannot be had says why in one plain line: the site's
  own words for what went wrong, or that the site could not reach its records.

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
      "for a person's own video, the launch's video for everyone, offered once the site has made all of the day's videos and they have none saved"

  attr :video_mine, :string,
    default: nil,
    doc:
      "a signed-in person's own video, offered behind a switch the window starts with off, so their wallet is shown only once they choose it"

  attr :mine_label, :string, default: "Mine", doc: "the words beside that switch"

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
          <label :if={@video && @video_mine} class="share-x__mine">
            <input type="checkbox" data-share-mine />
            <span>{@mine_label}</span>
          </label>
          <p :if={@video && @video_mine} class="share-x__note">
            On, your video also shows what your wallet holds here.
          </p>
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
              data-share-video-mine={@video_mine}
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
          <p :if={@video} class="share-x__note" data-share-video-note hidden></p>
          <p class="share-x__note">
            X opens with your post ready. Nothing is posted until you post it there.
          </p>
        </div>
      </dialog>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ShareDialog">
      // Every video this page has asked for, by its address, kept while the page
      // is open: closing the window, the page drawing it again, or another
      // window asking for the same video never loses one that is made or on
      // its way.
      const videos = new Map()

      const phone = () => window.matchMedia("(pointer: coarse)").matches

      // The plain line for a video that cannot be had: the site's own words for
      // what went wrong, or that the site could not reach its records. Anything
      // else, such as a dropped connection, keeps the window's own line.
      const unmade = "Your video couldn't be made just now. Try again in a moment."
      class Unanswered extends Error {}
      const unanswered = async (response) => {
        if (response.status === 503)
          return "The site couldn't reach its records just now. Try again in a moment."
        const answer = await response.json().catch(() => ({}))
        return answer.message || unmade
      }

      // Asks for the video until it is made. While it waits in line the answer
      // says how many videos are ahead of it; once the site has made all of the
      // day's videos, a person with none saved gets the launch's video instead.
      const want = (address, everyone, name) => {
        const kept = videos.get(address)
        if (kept && kept.state !== "failed") return kept

        const video = {state: "waiting", words: "", why: "", file: null, limited: false, watchers: new Set()}
        videos.set(address, video)
        const tell = () => video.watchers.forEach((watch) => watch(video))
        const until = Date.now() + 5 * 60 * 1000
        let asking = address

        const ask = () =>
          fetch(asking, {credentials: "same-origin"}).then(async (response) => {
            if (response.status === 200) return response.blob()

            if (response.status === 202 && Date.now() < until) {
              const {ahead} = await response.json()
              if (!video.limited)
                video.words = ahead > 0 ? `${ahead} ${ahead === 1 ? "video" : "videos"} ahead of yours` : "Making your video now"
              tell()
              await new Promise((resolve) => setTimeout(resolve, 2000))
              return ask()
            }

            throw new Unanswered(await unanswered(response))
          })

        ask()
          .then((blob) => {
            video.file = new File([blob], name, {type: "video/mp4"})
            video.state = "ready"
            if (!video.limited) video.words = ""
          })
          .catch((error) => {
            video.state = "failed"
            video.why = error instanceof Unanswered ? error.message : unmade
            if (!video.limited) video.words = ""
          })
          .finally(tell)

        return video
      }

      export default {
        mounted() {
          const dialog = this.el.querySelector("dialog")
          const message = dialog.querySelector("[data-share-message]")
          const post = dialog.querySelector("[data-share-post]")
          const button = () => this.el.querySelector("[data-share-video]")
          const mine = () => this.el.querySelector("[data-share-mine]")
          // The person's own video only once they switch it on in this opening
          // of the window. The choice lives here, not in the box, which the page
          // sets back as it draws itself again.
          this.mineOn = false
          const address = (el) =>
            this.mineOn && el.dataset.shareVideoMine ? el.dataset.shareVideoMine : el.dataset.shareVideo

          // What the window shows for its video, drawn again after every update
          // of the page, so the page never sets it back.
          this.show = () => {
            const video = this.video
            const el = button()
            if (mine()) mine().checked = this.mineOn
            if (!el || !video) return
            const label = el.querySelector("[data-share-video-label]")
            const status = this.el.querySelector("[data-share-video-status]")
            const note = this.el.querySelector("[data-share-video-note]")
            el.disabled = video.state === "waiting"
            label.textContent =
              video.state === "ready" ? (phone() ? "Share video" : "Download video")
              : video.state === "failed" ? "Try the video again"
              : "Preparing your video…"
            status.textContent = video.words
            status.hidden = !video.words
            note.textContent = video.why
            note.hidden = video.state !== "failed"
          }

          // The video is asked for once the window opens, so it is ready to hand
          // over the moment it is wanted.
          this.prepare = () => {
            const el = button()
            if (!el) return
            if (this.video) this.video.watchers.delete(this.show)
            this.video = want(address(el), el.dataset.shareVideoEveryone, el.dataset.shareVideoName)
            this.video.watchers.add(this.show)
            this.show()
          }

          // A phone hands the video to its share sheet; a computer saves it.
          const handOver = () => {
            if (!this.video || this.video.state === "failed") return this.prepare()
            const file = this.video.file
            if (!file) return
            if (phone() && navigator.canShare && navigator.canShare({files: [file]})) {
              navigator.share({files: [file], text: message.value}).catch(() => {})
            } else {
              const link = document.createElement("a")
              link.href = URL.createObjectURL(file)
              link.download = file.name
              link.click()
              setTimeout(() => URL.revokeObjectURL(link.href), 1000)
            }
          }

          // A video this page already has shows as it stands straight away.
          if (button() && videos.has(address(button()))) this.prepare()

          this.el.addEventListener("change", (event) => {
            if (!event.target.matches("[data-share-mine]")) return
            this.mineOn = event.target.checked
            this.prepare()
          })

          this.el.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-open]")) {
              this.mineOn = false
              dialog.showModal()
              this.prepare()
            }
            if (event.target.closest("[data-share-video]")) handOver()
          })
          dialog.addEventListener("click", (event) => {
            if (event.target.closest("[data-share-post], [data-share-close]") || event.target === dialog) dialog.close()
          })
          message.addEventListener("input", () => {
            post.href = "https://x.com/intent/post?" + new URLSearchParams({text: message.value})
          })
        },

        updated() {
          this.show && this.show()
        },

        destroyed() {
          if (this.video) this.video.watchers.delete(this.show)
        }
      }
    </script>
    """
  end

  defp intent(message), do: "https://x.com/intent/post?" <> URI.encode_query(%{text: message})
end
