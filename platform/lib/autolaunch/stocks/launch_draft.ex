defmodule Autolaunch.Stocks.LaunchDraft do
  @moduledoc """
  One private Stocks launch draft per human account, independent of the Agent
  draft. The creator moves it between Base and Robinhood; the token details go
  with it, and the paired stock is chosen again from the new chain's list.

  Every section autosaves partial text. Completeness is decided here in one
  place, and a change of paired stock puts the required raise and floor price
  back to their defaults, since amounts entered in the old stock mean nothing
  in the new one.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchDraftImage, LaunchDraftImageStorage}

  @token_fields [:name, :symbol, :description, :website, :telegram]
  @terms_fields [:stock_address, :required_raise, :floor_price]

  @metadata_limits [name: 64, symbol: 16, description: 512]

  # A Telegram link is optional; when given it is a public t.me address.
  @telegram ~r{\Ahttps://t\.me/[A-Za-z0-9_+/-]+\z}

  # The launchpads require a website, so a launch without one names this site,
  # which the site's pages never show as a creator's website.
  @site_website "https://autolaunch.sh"

  @doc "Whether the public token identity is complete."
  def token_details_complete?(draft), do: missing_token_details(draft) == []

  @doc "The fields a launch still needs, in the order the page shows them."
  def missing(draft), do: missing_token_details(draft) ++ missing_terms(draft)

  defp missing_token_details(draft) do
    for({field, limit} <- @metadata_limits, not within?(Map.get(draft, field), limit), do: field) ++
      if(optional_within?(Map.get(draft, :website), 256), do: [], else: [:website]) ++
      if(telegram_complete?(Map.get(draft, :telegram)), do: [], else: [:telegram]) ++
      if(image_complete?(draft), do: [], else: [:image])
  end

  defp optional_within?(value, _limit) when value in [nil, ""], do: true
  defp optional_within?(value, limit), do: within?(value, limit)

  defp telegram_complete?(value) when value in [nil, ""], do: true
  defp telegram_complete?(value), do: byte_size(value) <= 256 and value =~ @telegram

  @doc "The website a launch writes into its token: the creator's, or this site's."
  def onchain_website(%{website: website}) when website in [nil, ""], do: @site_website
  def onchain_website(%{website: website}), do: website

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
  Whether the currency, required raise and floor price are complete and exact.
  There is no schedule to enter: bidding opens a fixed number of blocks after
  the launch is created.
  """
  def terms_complete?(draft), do: missing_terms(draft) == []

  defp missing_terms(draft) do
    [
      stock_address:
        match?(
          {:ok, _stock},
          Assets.fetch(Map.get(draft, :stock_chain_id), Map.get(draft, :stock_address) || "")
        ),
      required_raise: decimal_amount?(Map.get(draft, :required_raise)),
      floor_price: decimal_amount?(Map.get(draft, :floor_price))
    ]
    |> Enum.reject(fn {_field, complete?} -> complete? end)
    |> Enum.map(fn {field, _complete?} -> field end)
  end

  def launch_ready?(draft), do: token_details_complete?(draft) and terms_complete?(draft)

  def token_fields, do: @token_fields
  def terms_fields, do: @terms_fields

  defp within?(value, limit),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit

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
      change Autolaunch.LaunchDraft.Changes.AssignOwner
      change Autolaunch.Stocks.LaunchDraft.Changes.DeriveStockChainId
      upsert? true
      upsert_identity :one_stocks_draft_per_human
      upsert_fields []
      return_skipped_upsert? true
    end

    read :mine_account_owned do
      get? true
      filter expr(human_account_id == ^actor(:human_account_id))
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

    update :autosave_terms do
      accept @terms_fields
      require_atomic? false
      validate Autolaunch.Stocks.LaunchDraft.Validations.PartialFields
      change Autolaunch.Stocks.LaunchDraft.Changes.ResetStockAmountsOnStockChange
    end

    # The stock list is per chain, so a new chain starts without a paired stock.
    update :choose_chain do
      accept [:chain]
      require_atomic? false
      change Autolaunch.Stocks.LaunchDraft.Changes.DeriveStockChainId
      change set_attribute(:stock_address, nil), where: [changing(:chain)]
      change Autolaunch.Stocks.LaunchDraft.Changes.ResetStockAmountsOnStockChange
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
             :choose_chain,
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
             :choose_chain,
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
    attribute :telegram, :string
    attribute :image, :string

    attribute :stock_address, :string
    attribute :stock_chain_id, :integer, allow_nil?: false
    attribute :required_raise, :string, default: "0.00001"
    attribute :floor_price, :string, default: "0.00000001"

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
    identity :one_stocks_draft_per_human, [:human_account_id]
  end
end
