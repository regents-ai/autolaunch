defmodule AutolaunchWeb.Components.ImagePicker do
  @moduledoc """
  The token image on both create pages: one box that shows the saved image, or
  the file being uploaded, beside the prompt. Choosing a file or dropping one
  on the box both work. It sits inside the token details form, whose change
  event carries the upload. Images are only stored for a signed-in account,
  so a page without an upload offers sign-in in the box instead.
  """
  use Phoenix.Component

  attr :upload, :map, default: nil, doc: "the page's upload, absent while signed out"
  attr :image, :string, default: "", doc: "the saved image's address"
  attr :notice, :string, default: nil, doc: "why the last file could not be saved"

  def image_upload(%{upload: nil} = assigns) do
    ~H"""
    <div class="image-upload">
      <span class="image-upload__label">Token image</span>
      <button type="button" class="image-upload__box" data-account-target="sign-in">
        <span class="image-upload__text">
          <strong>Sign in to add an image</strong>
          <span>PNG, JPEG or WebP, up to 2 MB · 400 × 400 px</span>
        </span>
      </button>
    </div>
    """
  end

  def image_upload(assigns) do
    upload = assigns.upload

    assigns =
      assign(assigns,
        image: assigns.image || "",
        errors: upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1))
      )

    ~H"""
    <div class="image-upload">
      <span class="image-upload__label">Token image</span>
      <label class="image-upload__box" for={@upload.ref} phx-drop-target={@upload.ref}>
        <.live_img_preview
          :for={entry <- @upload.entries}
          entry={entry}
          class="image-upload__preview"
        />
        <img
          :if={@upload.entries == [] && @image != ""}
          src={@image}
          alt="Saved token image"
          class="image-upload__preview"
        />
        <span class="image-upload__text">
          <strong>{if @image == "", do: "Choose image", else: "Replace image"}</strong>
          <span :for={entry <- @upload.entries}>Uploading · {entry.progress}%</span>
          <span :if={@upload.entries == []}>PNG, JPEG or WebP, up to 2 MB · 400 × 400 px</span>
        </span>
        <.live_file_input upload={@upload} class="visually-hidden" />
      </label>
      <p :for={error <- @errors} class="autolaunch-draft-error" role="alert">
        {upload_error(error)}
      </p>
      <p :if={@notice} class="autolaunch-draft-error" role="alert">{@notice}</p>
    </div>
    """
  end

  defp upload_error(:too_large), do: "Choose an image no larger than 2 MB."
  defp upload_error(:not_accepted), do: "Choose a PNG, JPEG, or WebP image."
  defp upload_error(:too_many_files), do: "Choose one image."
  defp upload_error(_error), do: "That image could not be uploaded."
end
