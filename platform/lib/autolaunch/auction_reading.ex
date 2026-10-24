defmodule Autolaunch.AuctionReading do
  @moduledoc """
  An auction's last reading of its own contract, one row per auction, written
  only by its reading job (`Autolaunch.AuctionMarket`): its figures
  (`Autolaunch.AuctionReading.Market`) and, for a Base auction, everything its
  own page shows (`Autolaunch.AuctionReading.Page`). `read_block` and
  `block_hash` name the block it was read at; `degraded` says the last attempt
  to read it again failed, so it is shown as it was.

  Every field is public on the chain itself, so a page reads the row as a
  signed-out visitor and each save publishes what changed, named field by
  field: the figures on `public:auction_market:<auction_id>`, a new page on
  `public:auction_page:<auction_id>`. `version` is set by the database and a
  page keeps the newer.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias Autolaunch.AuctionReading.{Market, Page}

  # The largest page a row holds: its price ladder lists a hundred prices and
  # packs every price it read, at most a thousand of 64 bytes each.
  @page_bytes 131_072

  postgres do
    table "auction_readings"
    repo Autolaunch.Repo

    references do
      reference :auction, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:auction_id, :read_block, :block_hash, :read_at, :degraded, :market, :page]
      validate {__MODULE__.PageSize, bytes: @page_bytes}
    end

    # A newer reading, or one from the block the chain moved to after leaving
    # the one before. A page left out stays as it was; `degraded` says the
    # page could not be read this time.
    update :refresh do
      require_atomic? false
      accept [:read_block, :block_hash, :read_at, :degraded, :market, :page]
      change increment(:version)
      validate {__MODULE__.PageSize, bytes: @page_bytes}
    end

    update :degrade do
      require_atomic? false
      accept []
      change set_attribute(:degraded, true)
      change increment(:version)
    end
  end

  policies do
    policy action(:read) do
      authorize_if always()
    end

    policy action([:record, :refresh, :degrade]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Autolaunch.PubSub
    prefix "public"
    broadcast_type :broadcast

    publish :record, ["auction_market", :auction_id], returns: :map, transform: &market(&1.data)
    publish :refresh, ["auction_market", :auction_id], returns: :map, transform: &market(&1.data)
    publish :degrade, ["auction_market", :auction_id], returns: :map, transform: &market(&1.data)

    publish :record, ["auction_page", :auction_id],
      returns: :map,
      transform: &page(&1.data),
      filter: &(&1.data.page != nil)

    publish :refresh, ["auction_page", :auction_id],
      returns: :map,
      transform: &page(&1.data),
      filter: &Ash.Changeset.changing_attribute?(&1.changeset, :page)
  end

  @doc "The topic an auction's figures are published on."
  def market_topic(auction_id), do: "public:auction_market:#{auction_id}"

  @doc "The topic an auction's own page is published on."
  def page_topic(auction_id), do: "public:auction_page:#{auction_id}"

  @doc """
  What a signed-out visitor may see of a reading's figures, named one by one:
  what the figures topic carries and what a page reads at mount.
  """
  def market(reading) do
    %{
      auction_id: reading.auction_id,
      version: reading.version,
      read_at: reading.read_at,
      read_block: reading.read_block,
      degraded: reading.degraded,
      market: reading.market
    }
  end

  @doc "What a signed-out visitor may see of an auction's own page."
  def page(reading),
    do: %{auction_id: reading.auction_id, version: reading.version, page: reading.page}

  attributes do
    attribute :read_block, :integer, allow_nil?: false, public?: true
    attribute :block_hash, :string, allow_nil?: false, public?: true
    attribute :read_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :degraded, :boolean, allow_nil?: false, default: false, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :market, Market, allow_nil?: false, public?: true
    attribute :page, Page, public?: true
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      primary_key? true
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  defmodule PageSize do
    @moduledoc false
    use Ash.Resource.Validation

    @impl true
    def validate(changeset, opts, _context) do
      case Ash.Changeset.get_attribute(changeset, :page) do
        nil ->
          :ok

        page ->
          if :erlang.external_size(page) <= opts[:bytes],
            do: :ok,
            else: {:error, field: :page, message: "is larger than a reading holds"}
      end
    end
  end
end
