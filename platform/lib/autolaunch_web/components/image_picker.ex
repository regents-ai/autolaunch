defmodule AutolaunchWeb.Components.ImagePicker do
  @moduledoc """
  The token image as one choice in one box: upload a file, or paste a link,
  split by a line marked OR. It sits inside the token details form, whose
  change event carries the upload; the link belongs to its own small form,
  `link_form/1`, placed after the details form so the two never nest.
  """
  use Phoenix.Component

  attr :id, :string, required: true, doc: "prefix for the picker's element ids"
  attr :upload, :map, default: nil
  attr :image, :string, default: nil, doc: "the saved image's address"
  attr :notice, :map, default: nil

  def image_picker(assigns) do
    ~H"""
    <div class="autolaunch-draft-field autolaunch-draft-field--wide image-picker">
      <span class="image-picker__label">Token image</span>
      <p class="autolaunch-draft-hint">
        PNG, JPEG, or WebP · maximum 2 MB. <strong>Recommended: 400 × 400 px</strong>
      </p>
      <div class="image-picker__box">
        <div class="image-picker__side">
          <label for={@upload && @upload.ref}>Upload a file</label>
          <div class="image-picker__file">
            <img
              :if={is_binary(@image) && @image != ""}
              class="autolaunch-image-preview"
              src={@image}
              alt="Saved token image"
            />
            <.live_file_input :if={@upload} upload={@upload} />
          </div>
        </div>
        <div class="image-picker__or" aria-hidden="true"><span>OR</span></div>
        <div class="image-picker__side">
          <label for={"#{@id}-url-input"}>Paste an image link</label>
          <div class="image-picker__link">
            <input
              type="text"
              id={"#{@id}-url-input"}
              name="url"
              form={"#{@id}-url"}
              autocomplete="off"
              aria-describedby={"#{@id}-notice"}
              placeholder="https://"
            />
            <Regent.Primitives.button type="submit" form={"#{@id}-url"} phx-disable-with="Fetching…">
              Use link
            </Regent.Primitives.button>
          </div>
        </div>
      </div>
      <div :for={entry <- (@upload && @upload.entries) || []} class="image-picker__entry">
        <.live_img_preview entry={entry} class="autolaunch-image-preview" />
        <p>{entry.client_name} · {entry.progress}%</p>
      </div>
      <p
        :for={error <- (@upload && upload_errors(@upload)) || []}
        class="autolaunch-draft-error"
        role="alert"
      >
        {upload_error(error)}
      </p>
      <p
        id={"#{@id}-notice"}
        role="status"
        aria-live="polite"
        class={
          if @notice && @notice.tone == :error,
            do: "autolaunch-draft-error",
            else: "autolaunch-draft-hint"
        }
      >
        {if @notice, do: @notice.message}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true

  @doc "The empty form the picker's link field and button submit through."
  def link_form(assigns) do
    ~H"""
    <form id={"#{@id}-url"} phx-submit={@event} hidden></form>
    """
  end

  defp upload_error(:too_large), do: "Choose an image no larger than 2 MB."
  defp upload_error(:not_accepted), do: "Choose a PNG, JPEG, or WebP image."
  defp upload_error(:too_many_files), do: "Choose one image."
  defp upload_error(_error), do: "That image could not be uploaded."
end
