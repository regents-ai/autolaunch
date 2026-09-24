defmodule Autolaunch.StoredImage do
  @moduledoc """
  The launch images the site stores, named by the address it gave each one:
  `/images/<id>/<digest>` for a Revstake draft's image and
  `/stock-images/<id>/<digest>` for a Memestake draft's, on any host.
  """

  @digest ~r/\A[0-9a-f]{64}\z/

  @type key :: {String.t(), String.t(), String.t()}

  @doc "The lane, id and digest an address names, or `:error` for any other address."
  @spec key(String.t()) :: {:ok, key()} | :error
  def key(url) when is_binary(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(url),
         [lane, id, digest] when lane in ["images", "stock-images"] <-
           String.split(path, "/", trim: true),
         {:ok, id} <- Ecto.UUID.cast(id),
         true <- Regex.match?(@digest, digest) do
      {:ok, {lane, id, digest}}
    else
      _other -> :error
    end
  end

  @doc "The bytes of the stored image an address names, or `:error`."
  @spec bytes(String.t() | nil) :: {:ok, binary()} | :error
  def bytes(url) when is_binary(url) do
    with {:ok, {lane, id, digest}} <- key(url),
         {:ok, %{bytes: bytes}} <- fetch(lane, id, digest) do
      {:ok, bytes}
    else
      _other -> :error
    end
  end

  def bytes(_url), do: :error

  defp fetch("images", id, digest),
    do: Autolaunch.get_public_launch_draft_image(id, digest, actor: nil)

  defp fetch("stock-images", id, digest),
    do: Autolaunch.get_public_stock_launch_draft_image(id, digest, actor: nil)
end
