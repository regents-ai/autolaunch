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
    :origin,
    :title,
    :summary,
    :token_symbol,
    :website,
    :telegram,
    :image,
    :creator_human_account_id,
    :creator_address,
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

  postgres do
    table "auctions"
    repo Autolaunch.Repo

    # Each public list reads its page straight off one of these in order.
    custom_indexes do
      index [:activity_due_at, :id], name: "auctions_activity_due_index"
      index [:estimated_end_at, :id], name: "auctions_ending_index"
      index ["bid_volume_usd DESC NULLS LAST", "id"], name: "auctions_bid_volume_index"

      index ["inserted_at DESC", "id"], name: "auctions_home_newest_index"
      index [:kind, :state], name: "auctions_kind_state_index"
    end
  end

  actions do
    read :activity_due do
      argument :historical, :boolean, default: false

      filter expr(
               if ^arg(:historical),
                 do: state in [:graduated, :failed],
                 else: state not in [:graduated, :failed]
             )

      filter expr(is_nil(activity_due_at) or activity_due_at <= now())
      prepare Autolaunch.Auction.Preparations.Listed

      prepare build(
                sort: [activity_due_at: :asc_nils_first, id: :asc],
                limit: 1,
                lock: :for_update
              )
    end

    # Not atomic: an atomic update re-reads through the primary read, which
    # hides Robinhood rows, so a Robinhood auction would never be claimed.
    update :schedule_activity do
      require_atomic? false
      accept [:activity_due_at]
    end

    update :refresh_activity do
      require_atomic? false

      accept [
        :activity_next_block,
        :activity_last_hash,
        :activity_due_at,
        :bid_volume,
        :bid_volume_usd,
        :opened_at,
        :estimated_end_at
      ]
    end

    read :read do
      primary? true
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
    end

    # Every auction the public lists carry, on both chains.
    read :listed do
      prepare Autolaunch.Auction.Preparations.Listed
      prepare build(load: [:path_tail])
    end

    read :list_public do
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare build(
                sort: [inserted_at: :desc, id: :asc],
                load: [:treasury_security_report, :path_tail]
              )
    end

    read :home_market do
      argument :x, :boolean, default: false
      argument :ens, :boolean, default: false
      argument :github, :boolean, default: false
      argument :query, :string, default: "", constraints: [allow_empty?: true, max_length: 80]
      argument :view, :string, default: "active", constraints: [match: ~r/\A(active|new)\z/]

      argument :state, :string,
        default: "all",
        constraints: [match: ~r/\A(all|created|active|ended|failed|graduated)\z/]

      argument :sort, :string,
        default: "newest",
        constraints: [match: ~r/\A(newest|ending|volume)\z/]

      argument :chain, :string, default: "all", constraints: [match: ~r/\A(all|base|robinhood)\z/]

      argument :kind, :string,
        default: "all",
        constraints: [match: ~r/\A(all|revstake|memestake)\z/]

      pagination keyset?: true, required?: true, default_limit: 24, max_page_size: 50
      prepare Autolaunch.Auction.Preparations.Listed

      # A query with a value the list does not know is refused as it stands.
      prepare fn
        %{valid?: false} = query, _context ->
          query

        query, _context ->
          states =
            if query.arguments.view == "active",
              do: [:created, :active, :ended],
              else: [:created, :active, :ended, :failed, :graduated]

          states =
            Enum.filter(
              states,
              &(query.arguments.state == "all" or Atom.to_string(&1) == query.arguments.state)
            )

          query =
            case query.arguments.chain do
              "base" ->
                Ash.Query.filter(query, chain_id == ^Autolaunch.Lab.chain_id())

              "robinhood" ->
                Ash.Query.filter(query, chain_id == ^Autolaunch.Robinhood.Lab.chain_id())

              "all" ->
                query
            end

          query =
            case query.arguments.kind do
              "revstake" -> Ash.Query.filter(query, kind == :agent)
              "memestake" -> Ash.Query.filter(query, kind == :stocks)
              "all" -> query
            end

          query =
            if query.arguments.x,
              do:
                Ash.Query.filter(
                  query,
                  exists(creator_x_connections, not is_nil(verified_at)) or
                    exists(creator_identities, provider == :x)
                ),
              else: query

          query =
            if query.arguments.ens,
              do: Ash.Query.filter(query, exists(creator_identities, provider == :ens)),
              else: query

          query =
            if query.arguments.github,
              do: Ash.Query.filter(query, exists(creator_identities, provider == :github)),
              else: query

          order =
            case query.arguments.sort do
              "ending" -> [estimated_end_at: :asc_nils_last, id: :asc]
              "volume" -> [bid_volume_usd: :desc_nils_last, id: :asc]
              "newest" -> [inserted_at: :desc, id: :asc]
            end

          query =
            if query.arguments.sort == "ending",
              do: Ash.Query.filter(query, state == :active),
              else: query

          query
          |> Ash.Query.filter(state in ^states)
          |> Ash.Query.load([:treasury_security_report, :path_tail])
          |> Autolaunch.Search.rank(query.arguments.query, order)
      end
    end

    read :recent_public do
      filter expr(state in [:created, :active, :ended, :failed])
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare build(
                sort: [inserted_at: :desc, id: :asc],
                limit: 12,
                load: [:treasury_security_report, :path_tail]
              )
    end

    read :featured_public do
      filter expr(featured == true)
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly

      prepare build(
                sort: [inserted_at: :desc, id: :asc],
                limit: 6,
                load: [:treasury_security_report, :path_tail]
              )
    end

    read :public_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(load: [:treasury_security_report, :path_tail])
    end

    # Any auction the public lists carry, by the id they give it.
    read :listed_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Auction.Preparations.Listed
      prepare build(load: [:treasury_security_report, :path_tail])
    end

    # The listed auctions a page address names: its ticker, in any case, and
    # the end of its contract address. More than one match means the address
    # is too short to name one auction.
    read :by_path do
      argument :symbol, :string, allow_nil?: false, constraints: [max_length: 16]

      argument :tail, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-fA-F]{5,40}\z/]

      filter expr(string_downcase(token_symbol) == string_downcase(^arg(:symbol)))
      prepare Autolaunch.Auction.Preparations.Listed
      prepare build(load: [:path_tail], limit: 2)

      prepare fn query, _context ->
        Ash.Query.filter(query, ilike(auction_address, ^("%" <> query.arguments.tail)))
      end
    end

    # The listed auctions sharing any of these tickers, ignoring case, which
    # decide how much of each address its page address needs; see
    # `Autolaunch.Auction.Calculations.PathTail`.
    read :path_peers do
      argument :symbols, {:array, :string}, allow_nil?: false
      filter expr(string_downcase(token_symbol) in ^arg(:symbols))
      prepare Autolaunch.Auction.Preparations.Listed
    end

    # A listed Robinhood auction, which its address names on the site.
    read :robinhood_by_address do
      get? true
      argument :auction_address, :string, allow_nil?: false
      filter expr(auction_address == ^arg(:auction_address))
      prepare Autolaunch.Auction.Preparations.Listed
      prepare build(load: [:path_tail])

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

    # A launch's auction row, written once by whichever of its writers comes
    # first (launch discovery, the creator's own confirmation, the Robinhood
    # feed). A row that already exists is returned exactly as it is, so no
    # later writer can blank its details or take its state back. The Robinhood
    # feed also records the launch's facts from its launchpad record. A Base
    # launch also binds the treasury report its creator reviewed, which every
    # bid on it is checked against.
    create :record_launch do
      accept @projection_accept ++
               [
                 :token_address,
                 :launch_id,
                 :start_block,
                 :end_block,
                 :treasury_security_report_id
               ]

      upsert? true
      upsert_identity :chain_auction
      upsert_condition expr(false)
      return_skipped_upsert? true
      change Autolaunch.Auction.Changes.ImageColor
      change fn changeset, _context -> TreasurySecurity.associate_report_address(changeset) end
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

      accept [
        :state,
        :current_clearing_price,
        :minimum_reached,
        :currency_raised,
        :floor_price,
        :token_supply
      ]
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
  end

  policies do
    policy action([:activity_due, :schedule_activity, :refresh_activity]) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action([
             :read,
             :listed,
             :listed_by_id,
             :robinhood_by_address,
             :by_path,
             :path_peers,
             :list_public,
             :home_market,
             :recent_public,
             :featured_public,
             :public_by_id,
             :by_chain_address
           ]) do
      authorize_if always()
    end

    policy action([
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
             :cancel_bid_review
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
    publish :refresh_activity, "listings"
    publish :set_bid_terms, "listings"
    publish :set_treasury_security_report, "listings"

    publish :refresh_lab_market, "listings",
      filter: fn %{changeset: %{data: before}, data: after_refresh} ->
        before.state != after_refresh.state or
          before.minimum_reached != after_refresh.minimum_reached
      end
  end

  attributes do
    attribute :activity_next_block, :integer
    attribute :activity_last_hash, :string
    attribute :activity_due_at, :utc_datetime_usec
    attribute :bid_volume, :decimal, public?: true
    attribute :bid_volume_usd, :decimal, public?: true
    attribute :estimated_end_at, :utc_datetime_usec, public?: true
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

    # A Memestake creator's Telegram community, kept by this site: it is not
    # part of the token's onchain metadata.
    attribute :telegram, :string do
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

    # Where the launch came from: `:site` when this site prepared it (on Base,
    # a review this site's account carried out; on Robinhood, a review stored
    # when the site prepared it), `:chain` when it was only seen on chain.
    # Only site launches are listed.
    attribute :origin, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:site, :chain]
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

    # The market feed's latest reading of what the auction has raised, in
    # whole quote-token units.
    attribute :currency_raised, :decimal do
      public? true
    end

    # The lowest price the auction sells at, in quote-token units per token,
    # and the launch token's total supply in whole tokens. Both are fixed when
    # the auction is created; the market feed reads them once.
    attribute :floor_price, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :token_supply, :decimal do
      public? true
    end

    attribute :treasury_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    # The wallet that launched the auction on chain, in lowercase.
    attribute :creator_address, :string do
      public? true
      allow_nil? false
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-f]{40}\z/
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

    has_many :creator_identities, Autolaunch.Accounts.LinkedIdentity do
      source_attribute :creator_human_account_id
      destination_attribute :human_account_id
    end

    has_many :creator_x_connections, Autolaunch.Accounts.XConnection do
      source_attribute :creator_human_account_id
      destination_attribute :human_account_id
    end

    belongs_to :treasury_security_report,
               Autolaunch.TreasurySecurityReport do
      attribute_public? true
    end

    # The stock a Stocks auction raises, when the site lists it.
    has_one :quote_stock, Autolaunch.Stocks.Stock do
      no_attributes? true

      filter expr(
               chain_id == parent(chain_id) and
                 string_downcase(address) == string_downcase(parent(quote_token_address))
             )
    end
  end

  calculations do
    # What every token is worth at the current clearing price, in quote-token units.
    calculate :fdv, :decimal, Autolaunch.Auction.Calculations.Fdv do
      public? true
    end

    # The end of the contract address the auction's page addresses carry.
    calculate :path_tail, :string, Autolaunch.Auction.Calculations.PathTail do
      public? true
    end

    # How closely a search matches this auction, from 0 to 1; see `Autolaunch.Search`.
    # The name, ticker and stock count fully, the creator's accounts a little
    # less and the description less again. `address` is set when the search
    # could be part of an address, and matches the auction, token and creator
    # wallet outright.
    calculate :search_rank,
              :float,
              expr(
                if not is_nil(^arg(:address)) and
                     (contains(string_downcase(auction_address), ^arg(:address)) or
                        contains(string_downcase(token_address), ^arg(:address)) or
                        contains(creator_address, ^arg(:address))) do
                  1.0
                else
                  fragment(
                    "greatest(word_similarity(?, concat_ws(' ', ?, ?, ?, ?)), 0.9 * word_similarity(?, array_to_string(? || ? || ? || ?, ' ')), 0.7 * word_similarity(?, coalesce(?, '')))",
                    ^arg(:term),
                    title,
                    token_symbol,
                    quote_token_symbol,
                    quote_stock_search_text,
                    ^arg(:term),
                    creator_identity_names,
                    creator_identity_display_names,
                    creator_x_names,
                    creator_x_display_names,
                    ^arg(:term),
                    summary
                  )
                end
              ) do
      argument :term, :string, allow_nil?: false
      argument :address, :string
    end
  end

  aggregates do
    # The creator's connected account names, for search.
    list :creator_identity_names, :creator_identities, :username do
      filter expr(provider in [:x, :github, :ens])
    end

    list :creator_identity_display_names, :creator_identities, :display_name do
      filter expr(provider in [:x, :github, :ens])
    end

    list :creator_x_names, :creator_x_connections, :username do
      filter expr(not is_nil(verified_at))
    end

    list :creator_x_display_names, :creator_x_connections, :display_name do
      filter expr(not is_nil(verified_at))
    end

    first :quote_stock_search_text, :quote_stock, :search_text
  end

  identities do
    identity :chain_auction, [:chain_id, :auction_address]
  end
end
