defmodule Autolaunch.LaunchDraftImageStorage do
  @moduledoc """
  Validates and stores one immutable launch image, then attaches its permanent
  content-addressed URL to the owner's draft in the same database transaction.
  """

  require Ash.Query

  alias Autolaunch.Actors.Human
  alias Autolaunch.{LaunchDraft, LaunchDraftImage}
  alias Autolaunch.LaunchDraft.ImageValidator

  @type stored :: %{
          image: Ash.Resource.record(),
          draft: Ash.Resource.record(),
          reused?: boolean()
        }

  @spec store_and_attach(Ash.Resource.record(), binary(), String.t(), String.t(), struct()) ::
          {:ok, stored()} | {:error, term()}
  def store_and_attach(
        %LaunchDraft{human_account_id: owner_id} = draft,
        bytes,
        declared_type,
        original_filename,
        %Human{human_account_id: owner_id} = actor
      )
      when is_binary(bytes) do
    transact(draft.id, bytes, declared_type, original_filename, sha256(bytes), actor)
  end

  def store_and_attach(_draft, _bytes, _declared_type, _filename, _actor),
    do: {:error, :image_unavailable}

  @spec public_url(Ash.Resource.record()) :: String.t()
  def public_url(%LaunchDraftImage{id: id, digest: digest}) do
    AutolaunchWeb.Endpoint.url() <> "/images/#{id}/#{digest}"
  end

  @spec validate(binary(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  defdelegate validate(bytes, declared_type), to: ImageValidator

  defp transact(draft_id, bytes, content_type, original_filename, digest, actor) do
    Ash.DataLayer.transaction(LaunchDraft, fn ->
      store_transaction(draft_id, bytes, content_type, original_filename, digest, actor)
    end)
  end

  defp store_transaction(draft_id, bytes, content_type, original_filename, digest, actor) do
    with {:ok, draft} <- locked_draft(draft_id, actor),
         {:ok, image, reused?} <-
           existing_or_store(draft, bytes, content_type, original_filename, digest, actor),
         url <- public_url(image),
         :ok <- bounded_url(url),
         {:ok, _attached} <- attach(draft, image, actor),
         {:ok, attached} <- Autolaunch.get_my_launch_draft(draft.id, actor: actor) do
      %{image: image, draft: attached, reused?: reused?}
    else
      {:error, error} -> Ash.DataLayer.rollback(LaunchDraft, normalize_error(error))
    end
  end

  defp locked_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft_for_update(draft_id, actor: actor) do
      {:ok, nil} -> {:error, :image_unavailable}
      result -> result
    end
  end

  defp existing_or_store(draft, bytes, content_type, original_filename, digest, actor) do
    case Autolaunch.get_my_launch_draft_image_for_reuse(draft.id, actor: actor) do
      {:ok, nil} ->
        create_image(draft, bytes, content_type, original_filename, actor)

      {:ok,
       %{
         digest: ^digest,
         content_type: ^content_type,
         byte_size: stored_size,
         bytes: ^bytes
       } = image}
      when stored_size == byte_size(bytes) ->
        {:ok, image, true}

      {:ok, _different_image} ->
        {:error, :image_limit_reached}

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_image(draft, bytes, content_type, original_filename, actor) do
    case Autolaunch.create_launch_draft_image(
           bytes,
           content_type,
           original_filename,
           draft.id,
           actor: actor
         ) do
      {:ok, image} ->
        {:ok, image, false}

      {:error, error} ->
        {:error, error}
    end
  end

  defp attach(draft, image, actor) do
    Autolaunch.attach_launch_draft_image(draft, image.id, actor: actor)
  end

  defp bounded_url(url) when is_binary(url) and byte_size(url) <= 256, do: :ok
  defp bounded_url(_url), do: {:error, :image_url_too_long}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp normalize_error(%{errors: errors} = error) when is_list(errors) do
    cond do
      Enum.any?(errors, &(inspect(&1) =~ "one_image_per_draft")) ->
        :image_limit_reached

      validation_error?(errors, "invalid_image") ->
        :invalid_image

      validation_error?(errors, "image_too_large") ->
        :image_too_large

      true ->
        error
    end
  end

  defp normalize_error(error), do: error

  defp validation_error?(errors, expected) do
    Enum.any?(errors, fn
      %{message: ^expected} -> true
      error -> inspect(error) =~ expected
    end)
  end
end
