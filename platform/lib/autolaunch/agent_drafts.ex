defmodule Autolaunch.AgentDrafts do
  @moduledoc """
  A paired agent's reads and saves of its person's launch draft, Revstake or
  Memestock. An agent can fill in everything the person's create form takes:
  the token's details, its picture and its launch settings (a Revstake
  draft's treasury, a Memestock draft's chain and paired stock). It cannot
  give the person's own acknowledgement for a treasury owned by a private
  key, launch, or sign anything: the person opens the create page, sees
  every field the agent set named in the review, and signs.

  A save is one transaction. It opens the draft through the agent's own
  action, which locks the pairing first, so a pairing revoked meanwhile saves
  nothing and nothing is stored for the person before the pairing is checked.
  The fields follow, then the picture. Once the save has committed, the
  person's open create page hears of it (`subscribe/2`).
  """

  alias Autolaunch.Actors.{Agent, Human}
  alias Autolaunch.{LaunchDraft, LaunchDraftImageStorage}
  alias Autolaunch.Stocks.LaunchDraft, as: StocksDraft
  alias Autolaunch.Stocks.LaunchDraftImageStorage, as: StocksImageStorage

  @kinds %{
    "revstake" => {LaunchDraft, LaunchDraftImageStorage},
    "memestock" => {StocksDraft, StocksImageStorage}
  }

  @doc """
  Tells the calling process each time a paired agent's save of the draft of
  `kind` for `human_account_id` commits, as `{:agent_draft_saved, kind}`.
  """
  def subscribe(kind, human_account_id),
    do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(kind, human_account_id))

  @doc "The fields an agent may send for `kind`, as JSON names; `image` takes a picture."
  def fields(kind) do
    {resource, _storage} = Map.fetch!(@kinds, kind)
    Enum.map(resource.agent_fields(), &Atom.to_string/1) ++ ["image"]
  end

  @doc "The person's draft of `kind`, or nil before there is one."
  @spec read(String.t(), struct()) :: {:ok, struct() | nil} | {:error, term()}
  def read(kind, %Agent{} = actor) do
    with {:ok, {resource, _storage}} <- kind(kind),
         do: resource |> Ash.Query.for_read(:agent_read, %{}, actor: actor) |> Ash.read_one()
  end

  @doc """
  Saves `params` on the person's draft of `kind`: text fields as strings, and
  `image` as `%{"content_type" => type, "data" => base64}`. Refuses any other
  field or shape whole, before anything is written.
  """
  @spec save(String.t(), map(), struct()) ::
          {:ok, struct()} | {:error, :invalid_draft | :invalid_image | :image_too_large}
  def save(kind, params, %Agent{} = actor) do
    with {:ok, {resource, storage}} <- kind(kind),
         {:ok, fields, image} <- split(kind, params),
         {:ok, draft} <-
           Ash.DataLayer.transaction(resource, fn ->
             write(resource, storage, fields, image, actor)
           end) do
      Phoenix.PubSub.broadcast(
        Autolaunch.PubSub,
        topic(kind, actor.human_account_id),
        {:agent_draft_saved, kind}
      )

      {:ok, draft}
    end
  end

  # Ash's own transaction wrappers turn a refusal into a general error; the
  # agent API answers each reason by name.
  defp write(resource, storage, fields, image, actor) do
    with {:ok, draft} <- draft(resource, actor),
         {:ok, draft} <- save_fields(draft, fields, actor),
         {:ok, draft} <- save_image(draft, image, storage, actor) do
      draft
    else
      {:error, reason} when reason in [:invalid_image, :image_too_large] ->
        Ash.DataLayer.rollback(resource, reason)

      {:error, :too_many_pixels} ->
        Ash.DataLayer.rollback(resource, :image_too_large)

      _refused ->
        Ash.DataLayer.rollback(resource, :invalid_draft)
    end
  end

  defp topic(kind, human_account_id), do: "#{kind}_agent_draft:#{human_account_id}"

  defp kind(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :invalid_draft}
    end
  end

  defp split(kind, params) when is_map(params) and map_size(params) > 0 do
    {image, fields} = Map.pop(params, "image")
    allowed = fields(kind)

    with true <- Enum.all?(fields, fn {key, value} -> key in allowed and is_binary(value) end),
         {:ok, image} <- picture(image) do
      {:ok, fields, image}
    else
      _invalid -> {:error, :invalid_draft}
    end
  end

  defp split(_kind, _params), do: {:error, :invalid_draft}

  defp picture(nil), do: {:ok, nil}

  defp picture(%{"content_type" => type, "data" => data} = image)
       when map_size(image) == 2 and is_binary(type) and is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, %{content_type: type, bytes: bytes}}
      :error -> {:error, :invalid_draft}
    end
  end

  defp picture(_image), do: {:error, :invalid_draft}

  # The person's draft, made when there is none yet. Its action locks the
  # pairing until the save commits, before anything is written.
  defp draft(resource, actor),
    do: resource |> Ash.Changeset.for_create(:agent_create, %{}, actor: actor) |> Ash.create()

  defp save_fields(draft, fields, _actor) when map_size(fields) == 0, do: {:ok, draft}

  defp save_fields(draft, fields, actor),
    do: draft |> Ash.Changeset.for_update(:agent_save, fields, actor: actor) |> Ash.update()

  defp save_image(draft, nil, _storage, _actor), do: {:ok, draft}

  # The picture is stored as the person's own upload is, under the account the
  # pairing names, while the pairing `draft/2` locked is still held; the
  # draft's agent action then names it as the agent's.
  defp save_image(draft, image, storage, actor) do
    owner = %Human{human_account_id: actor.human_account_id}

    with {:ok, %{draft: stored}} <-
           storage.store_and_attach(
             draft,
             image.bytes,
             image.content_type,
             "agent-picture",
             owner
           ) do
      stored |> Ash.Changeset.for_update(:agent_mark_image, %{}, actor: actor) |> Ash.update()
    end
  end

  @doc "A draft as the agent API answers it."
  def present(nil), do: nil

  def present(%StocksDraft{} = draft),
    do: Map.merge(shared(draft), Map.take(draft, [:chain, :stock_address]))

  def present(%LaunchDraft{} = draft),
    do: Map.merge(shared(draft), Map.take(draft, [:treasury, :treasury_path]))

  defp shared(draft),
    do:
      Map.take(draft, [
        :id,
        :name,
        :symbol,
        :description,
        :website,
        :telegram,
        :discord,
        :other_link_1,
        :other_link_2,
        :other_link_3,
        :image,
        :agent_set_fields,
        :updated_at,
        :last_agent_pairing_id
      ])
end
