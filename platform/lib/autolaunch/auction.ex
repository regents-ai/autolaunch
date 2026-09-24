defmodule Autolaunch.Auction do
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    primary_read_warning?: false

  alias Autolaunch.{BidActions, TreasurySecurity}
  require Ash.Query

  @projection_accept [
    :kind,
    :title,
    :summary,
    :token_symbol,
    :website,
    :image,
    :creator_human_account_id,
    :featured,
    :state,
    :opened_at,
    :auction_address,
    :quote_token_address,
    :quote_token_symbol,
    :quote_token_decimals,
    :current_clearing_price,
    :required_currency_raised,
    :treasury_address,
    :chain_id
  ]

  @projection_upsert [
    :kind,
    :title,
    :summary,
    :token_symbol,
    :website,
    :image,
    :creator_human_account_id,
    :state,
    :opened_at,
    :auction_address,
    :quote_token_address,
    :quote_token_symbol,
    :quote_token_decimals,
    :current_clearing_price,
    :treasury_address,
    :image_color
  ]

  postgres do
    table "auctions"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
    end

    # Every auction the public lists carry, on both chains.
    read :listed do
      prepare Autolaunch.Auction.Preparations.Listed
    end

    read :list_public do
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(sort: [inserted_at: :desc, id: :asc], load: [:treasury_security_report])
    end

    read :home_market do
      argument :query, :string, default: "", constraints: [allow_empty?: true, max_length: 80]
      argument :view, :string, default: "active", constraints: [match: ~r/\A(active|new)\z/]

      argument :state, :string,
        default: "all",
        constraints: [match: ~r/\A(all|created|active|ended|failed)\z/]

      argument :sort, :string, default: "newest", constraints: [match: ~r/\A(newest|oldest)\z/]
      pagination keyset?: true, required?: true, default_limit: 24, max_page_size: 24
      prepare Autolaunch.Auction.Preparations.Listed

      prepare fn query, _context ->
        states =
          if query.arguments.view == "active",
            do: [:created, :active, :ended],
            else: [:created, :active, :ended, :failed]

        states =
          Enum.filter(
            states,
            &(query.arguments.state == "all" or Atom.to_string(&1) == query.arguments.state)
          )

        direction = if query.arguments.sort == "oldest", do: :asc, else: :desc

        query
        |> market_query(states, nil)
        |> Ash.Query.unset([:sort, :limit])
        |> Ash.Query.sort([{:inserted_at, direction}, {:id, :asc}])
      end
    end

    read :page_public do
      argument :mode, :string,
        default: "all",
        constraints: [match: ~r/\A(all|biddable|live|ended|failed_minimum|graduated)\z/]

      argument :sort, :string, default: "newest", constraints: [match: ~r/\A(newest|oldest)\z/]
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 50
      prepare Autolaunch.Auction.Preparations.Listed
      prepare build(load: [:treasury_security_report])

      prepare fn query, _context ->
        query =
          case Ash.Query.get_argument(query, :mode) do
            mode when mode in ["live", "biddable"] -> Ash.Query.filter(query, state == :active)
            "ended" -> Ash.Query.filter(query, state == :ended)
            "failed_minimum" -> Ash.Query.filter(query, state == :failed)
            "graduated" -> Ash.Query.filter(query, state == :graduated)
            "all" -> query
          end

        case Ash.Query.get_argument(query, :sort) do
          "oldest" ->
            Ash.Query.sort(query, opened_at: :asc, inserted_at: :asc, id: :asc)

          "newest" ->
            Ash.Query.sort(query, opened_at: :desc_nils_last, inserted_at: :desc, id: :asc)
        end
      end
    end

    read :recent_public do
      filter expr(state in [:created, :active, :ended, :failed])
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare build(
                sort: [inserted_at: :desc, id: :asc],
                limit: 12,
                load: [:treasury_security_report]
              )
    end

    read :featured_public do
      filter expr(featured == true)
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare build(
                sort: [inserted_at: :desc, id: :asc],
                limit: 6,
                load: [:treasury_security_report]
              )
    end

    read :active_launchpad do
      argument :query, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, max_length: 80]

      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare fn query, _context -> market_query(query, [:created, :active, :ended], 8) end
    end

    read :explore_launchpad do
      argument :query, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, max_length: 80]

      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare fn query, _context ->
        market_query(query, [:created, :active, :ended, :failed], 24)
      end
    end

    read :public_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(load: [:treasury_security_report])
    end

    # A listed Robinhood auction, which its address names on the site.
    read :robinhood_by_address do
      get? true
      argument :auction_address, :string, allow_nil?: false
      filter expr(auction_address == ^arg(:auction_address))
      prepare Autolaunch.Auction.Preparations.Listed

      prepare fn query, _context ->
        Ash.Query.filter(query, chain_id == ^Autolaunch.Robinhood.Lab.chain_id())
      end
    end

    read :by_chain_address do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :auction_address, :string, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and auction_address == ^arg(:auction_address))
    end

    # One page of the auctions a market feed watches, in id order after a
    # cursor: the open ones (not yet graduated or failed) or the finished
    # ones. Each feed pass reads a bounded page and moves the cursor on, so
    # every auction is covered over successive passes however many there are.
    read :market_watch do
      argument :chain_id, :integer, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:agent, :stocks]]
      argument :finished, :boolean, allow_nil?: false
      argument :after_id, :uuid
      argument :limit, :integer, allow_nil?: false, constraints: [min: 1, max: 500]

      filter expr(kind == ^arg(:kind) and chain_id == ^arg(:chain_id))

      prepare fn query, _context ->
        %{finished: finished, after_id: after_id, limit: limit} = query.arguments
        states = if finished, do: [:graduated, :failed], else: [:created, :active, :ended]

        query
        |> Ash.Query.filter(state in ^states)
        |> then(&if(after_id, do: Ash.Query.filter(&1, id > ^after_id), else: &1))
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(limit)
      end
    end

    read :lab_by_id_for_update do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare build(lock: :for_update)
    end

    create :project_lab do
      accept @projection_accept
      upsert? true
      upsert_identity :chain_auction
      upsert_fields @projection_upsert
      change Autolaunch.Auction.Changes.ImageColor
    end

    # A launch's auction row, written once by whichever of its writers comes
    # first (launch discovery, the creator's own confirmation, the Robinhood
    # feed). A row that already exists is returned exactly as it is, so no
    # later writer can blank its details or take its state back.
    create :record_launch do
      accept @projection_accept
      upsert? true
      upsert_identity :chain_auction
      upsert_condition expr(false)
      return_skipped_upsert? true
      change Autolaunch.Auction.Changes.ImageColor
    end

    update :set_bid_terms do
      require_atomic? false

      accept [
        :auction_address,
        :quote_token_address,
        :quote_token_symbol,
        :quote_token_decimals,
        :current_clearing_price
      ]
    end

    update :refresh_lab_market do
      require_atomic? false
      accept [:state, :current_clearing_price, :minimum_reached]
    end

    update :set_treasury_security_report do
      require_atomic? false
      accept [:treasury_security_report_id]
      change fn changeset, _context -> TreasurySecurity.associate_report_address(changeset) end
    end

    # The bidder lifecycle. Every one of these names the exact wallet or the
    # exact operation it acts on, and `BidActions` proves both against the
    # account the mounted lease locks before anything durable moves.
    action :bid_position, :map do
      argument :auction_id, :uuid, allow_nil?: false
      argument :expected_signer, :string, allow_nil?: false
      run fn input, context -> BidActions.position(input, context) end
    end

    action :prepare_bid, :map do
      argument :auction_id, :uuid, allow_nil?: false
      argument :expected_signer, :string, allow_nil?: false
      argument :amount, :string, allow_nil?: false
      argument :max_price, :string, allow_nil?: false
      run fn input, context -> BidActions.prepare(input, context) end
    end

    # A USDC bid on a Stocks auction: the adapter buys the stock through the
    # admitted route and bids as the caller, inside one transaction.
    action :prepare_usdc_bid, :map do
      argument :auction_id, :uuid, allow_nil?: false
      argument :expected_signer, :string, allow_nil?: false
      argument :usdc_amount, :string, allow_nil?: false
      argument :max_price, :string, allow_nil?: false
      run fn input, context -> BidActions.prepare_usdc(input, context) end
    end

    action :cancel_bid_review, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.cancel(input, context) end
    end

    action :start_new_bid, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.start_new_bid(input, context) end
    end
  end

  policies do
    policy action([
             :read,
             :listed,
             :robinhood_by_address,
             :list_public,
             :page_public,
             :home_market,
             :recent_public,
             :featured_public,
             :active_launchpad,
             :explore_launchpad,
             :public_by_id,
             :by_chain_address
           ]) do
      authorize_if always()
    end

    policy action([
             :project_lab,
             :record_launch,
             :market_watch,
             :lab_by_id_for_update,
             :refresh_lab_market
           ]) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action(:set_bid_terms) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action(:set_treasury_security_report) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action([
             :bid_position,
             :prepare_bid,
             :prepare_usdc_bid,
             :cancel_bid_review,
             :start_new_bid
           ]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end
  end

  # What the public lists show changed; see `Autolaunch.Listings`. The market
  # feed's price moves are left to its own topic, so only a state or minimum
  # change from a refresh reaches the lists.
  pub_sub do
    module Phoenix.PubSub
    name Autolaunch.PubSub
    transform fn notification -> {:autolaunch_listings_changed, notification.data.id} end

    publish_all :create, "listings"
    publish :set_bid_terms, "listings"
    publish :set_treasury_security_report, "listings"

    publish :refresh_lab_market, "listings",
      filter: fn %{changeset: %{data: before}, data: after_refresh} ->
        before.state != after_refresh.state or
          before.minimum_reached != after_refresh.minimum_reached
      end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :summary, :string do
      public? true
      constraints max_length: 2_000, trim?: true
    end

    attribute :token_symbol, :string do
      public? true
      constraints max_length: 16, trim?: true
    end

    attribute :website, :string do
      public? true
      constraints max_length: 256, trim?: true
    end

    attribute :image, :string do
      public? true
      constraints max_length: 256, trim?: true
    end

    # The colour of the image, when the image is one the site stores.
    attribute :image_color, :string do
      public? true
      constraints match: ~r/\A#[0-9a-f]{6}\z/, max_length: 7
    end

    attribute :featured, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # Which launch mode created this auction. Agent auctions raise REGENT;
    # Stocks auctions raise the admitted Base stock token named by the quote
    # token fields.
    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :agent
      constraints one_of: [:agent, :stocks]
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :created
      constraints one_of: [:created, :active, :ended, :graduated, :failed]
    end

    # The raise has met its minimum. A progress fact only: bidding stays open
    # until the end block, and only the launch's own finish makes it final.
    attribute :minimum_reached, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :opened_at, :utc_datetime_usec do
      public? true
    end

    # One auction contract on one chain is one row; the same address on
    # another chain is another auction.
    attribute :chain_id, :integer do
      public? true
      allow_nil? false
      constraints min: 1
    end

    attribute :auction_address, :string do
      public? true
      allow_nil? false
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :quote_token_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :quote_token_symbol, :string do
      public? true
      constraints min_length: 1, max_length: 32, trim?: true
    end

    attribute :quote_token_decimals, :integer do
      public? true
      constraints min: 0, max: 36
    end

    attribute :current_clearing_price, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :treasury_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    # What the auction must raise to graduate, in the quote token's smallest
    # units. The auction contract keeps it without a getter, so the launch
    # that set it is the record of it.
    attribute :required_currency_raised, :string do
      public? true
      allow_nil? false
      constraints match: ~r/\A[1-9][0-9]{0,38}\z/
    end

    # What a Robinhood launch recorded when its auction opened: the token it
    # sells, its launch number on the launchpad and its bidding window.
    attribute :token_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :launch_id, :integer do
      public? true
      constraints min: 1
    end

    attribute :start_block, :integer do
      public? true
      constraints min: 0
    end

    attribute :end_block, :integer do
      public? true
      constraints min: 0
    end

    timestamps()
  end

  relationships do
    # The account whose signed-in wallet launched the auction. Every Base
    # auction the site lists has one; a Robinhood launch is listed from the
    # launchpad's own records and names one only when exactly one account's
    # signed-in wallet is its launcher (`Autolaunch.Robinhood.MarketFeed`).
    belongs_to :creator_human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? true
      attribute_public? true
      attribute_type :integer
    end

    has_many :creator_x_connections, Autolaunch.Accounts.XConnection do
      source_attribute :creator_human_account_id
      destination_attribute :human_account_id
    end

    belongs_to :treasury_security_report,
               Autolaunch.TreasurySecurityReport do
      attribute_public? true
    end
  end

  defp market_query(query, states, limit) do
    term = query.arguments.query |> String.trim() |> String.downcase()
    pattern = literal_search_pattern(term)

    query
    |> Ash.Query.filter(state in ^states)
    |> market_search_filter(term, pattern)
    |> Ash.Query.sort(inserted_at: :desc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:treasury_security_report)
  end

  defp market_search_filter(query, "", _pattern), do: query

  defp market_search_filter(query, _term, pattern) do
    Ash.Query.filter(
      query,
      ilike(title, ^pattern) or
        ilike(summary, ^pattern) or
        ilike(token_symbol, ^pattern) or
        ilike(auction_address, ^pattern) or
        ilike(token_address, ^pattern) or
        exists(
          creator_x_connections,
          not is_nil(verified_at) and
            (ilike(username, ^pattern) or ilike(display_name, ^pattern))
        )
    )
  end

  defp literal_search_pattern(term) do
    "%" <>
      (term
       |> String.replace("\\", "\\\\")
       |> String.replace("%", "\\%")
       |> String.replace("_", "\\_")) <> "%"
  end

  identities do
    identity :chain_auction, [:chain_id, :auction_address]
  end
end
