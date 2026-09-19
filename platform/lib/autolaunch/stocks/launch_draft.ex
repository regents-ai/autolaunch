defmodule Autolaunch.Stocks.LaunchDraft do
  @moduledoc """
  One private Stocks launch draft per human account and chain, independent of the Agent draft.

  Every section autosaves partial text. Completeness is decided here in one
  place, and a change of auction currency clears the floor price that was
  entered in the old currency so a review can never mix them. The minimum raise
  is the launchpad's own USDC minimum, so no draft carries one.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchDraftImage, LaunchDraftImageStorage}

  @token_fields [:name, :symbol, :description, :website]
  @terms_fields [:stock_address, :start_at, :start_timezone, :floor_price]

  @metadata_limits [name: 64, symbol: 16, description: 512, website: 256]

  @doc "Whether the public token identity is complete."
  def token_details_complete?(draft) do
    Enum.all?(@metadata_limits, fn {field, limit} -> within?(Map.get(draft, field), limit) end) and
      image_complete?(draft)
  end

  @doc "Whether this draft carries the only image shape its provenance permits."
  def image_complete?(%{
        id: draft_id,
        human_account_id: human_account_id,
        stock_launch_draft_image_id: image_id,
        stock_launch_draft_image: %LaunchDraftImage{} = owned_image,
        image: image
      })
      when is_binary(draft_id) and is_integer(human_account_id) and is_binary(image_id) and
             is_binary(image) do
    owned_image.id == image_id and
      owned_image.human_account_id == human_account_id and
      owned_image.stock_launch_draft_id == draft_id and
      owned_image.digest =~ ~r/\A[0-9a-f]{64}\z/ and
      image == LaunchDraftImageStorage.public_url(owned_image) and
      byte_size(image) <= 256
  end

  def image_complete?(_draft), do: false

  @doc """
  Whether the currency, schedule and floor price are complete and exact. A
  Robinhood launch has no schedule to enter: bidding opens a fixed number of
  blocks after the review.
  """
  def terms_complete?(%{chain: :robinhood} = draft) do
    match?({:ok, _stock}, Assets.fetch(draft.stock_chain_id, draft.stock_address || "")) and
      decimal_amount?(draft.floor_price)
  end

  def terms_complete?(draft) do
    match?({:ok, _stock}, Assets.fetch(draft.stock_chain_id, draft.stock_address || "")) and
      match?(%DateTime{}, draft.start_at) and
      timezone?(draft.start_timezone) and
      decimal_amount?(draft.floor_price)
  end

  def launch_ready?(draft), do: token_details_complete?(draft) and terms_complete?(draft)

  def token_fields, do: @token_fields
  def terms_fields, do: @terms_fields

  defp within?(value, limit),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit

  @doc "Whether `value` names an IANA zone the bundled table knows."
  def timezone?(value) when is_binary(value),
    do: match?({:ok, _}, DateTime.now(value))

  def timezone?(_value), do: false

  defp decimal_amount?(value) when is_binary(value),
    do: match?({:ok, raw} when raw > 0, Amounts.parse_units(value, 36))

  defp decimal_amount?(_value), do: false

  postgres do
    table "stock_launch_drafts"
    repo Autolaunch.Repo

    custom_indexes do
      index [:stock_launch_draft_image_id]
    end

    references do
      reference :human_account, on_delete: :restrict
      reference :stock_launch_draft_image, on_delete: :restrict
    end
  end

  actions do
    create :create_for_owner do
      accept [:chain]
      change Autolaunch.LaunchDraft.Changes.AssignOwner
      change Autolaunch.Stocks.LaunchDraft.Changes.DeriveStockChainId
      upsert? true
      upsert_identity :one_stocks_draft_per_human_and_chain
      upsert_fields []
      return_skipped_upsert? true
    end

    read :mine_account_owned do
      get? true
      argument :chain, :atom, allow_nil?: false, constraints: [one_of: LaunchChain.chains()]
      filter expr(human_account_id == ^actor(:human_account_id) and chain == ^arg(:chain))
      prepare build(load: [:stock_launch_draft_image])
    end

    read :mine_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(human_account_id == ^actor(:human_account_id) and id == ^arg(:id))
      prepare build(load: [:stock_launch_draft_image])
    end

    read :mine_by_id_for_update do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(human_account_id == ^actor(:human_account_id) and id == ^arg(:id))
      prepare build(load: [:stock_launch_draft_image])
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    update :autosave_token_details do
      accept @token_fields
      require_atomic? false
      validate Autolaunch.Stocks.LaunchDraft.Validations.PartialFields
    end

    # The start arrives as the wall-clock text the creator typed plus the IANA
    # zone it was typed in; the exact UTC instant is derived here, once.
    update :autosave_terms do
      accept [:stock_address, :start_timezone, :floor_price]
      argument :start_local, :string, constraints: [allow_empty?: true, max_length: 32]
      require_atomic? false
      validate Autolaunch.Stocks.LaunchDraft.Validations.PartialFields
      change Autolaunch.Stocks.LaunchDraft.Changes.DeriveStartAt
      change Autolaunch.Stocks.LaunchDraft.Changes.ClearFloorPriceOnStockChange
    end

    update :attach_image do
      argument :stock_launch_draft_image_id, :uuid, allow_nil?: false
      require_atomic? false
      change Autolaunch.Stocks.LaunchDraft.Changes.AttachOwnedImage
    end
  end

  policies do
    policy action([
             :create_for_owner,
             :mine_account_owned,
             :mine_by_id,
             :mine_by_id_for_update,
             :autosave_token_details,
             :autosave_terms,
             :attach_image
           ]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action([
             :mine_account_owned,
             :mine_by_id,
             :mine_by_id_for_update,
             :autosave_token_details,
             :autosave_terms,
             :attach_image
           ]) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain, :atom do
      allow_nil? false
      public? true
      default :base
      constraints one_of: LaunchChain.chains()
    end

    attribute :name, :string, allow_nil?: false, default: "", constraints: [allow_empty?: true]
    attribute :symbol, :string, allow_nil?: false, default: "", constraints: [allow_empty?: true]
    attribute :description, :string
    attribute :website, :string
    attribute :image, :string

    attribute :stock_address, :string
    attribute :stock_chain_id, :integer, allow_nil?: false
    attribute :start_at, :utc_datetime
    attribute :start_timezone, :string
    attribute :floor_price, :string

    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :stock_launch_draft_image, Autolaunch.Stocks.LaunchDraftImage do
      allow_nil? true
    end
  end

  identities do
    identity :one_stocks_draft_per_human_and_chain, [:human_account_id, :chain]
  end
end
