defmodule Autolaunch.Token do
  alias Autolaunch.SubjectIdentity

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    primary_read_warning?: false

  require Ash.Query

  postgres do
    table "tokens"
    repo Autolaunch.Repo

    # The public token lists read their page straight off this in order.
    custom_indexes do
      index ["graduated_at DESC", "id"], name: "tokens_graduated_newest_index"
      index [:trades_due_at, :id], name: "tokens_trades_due_index"
    end
  end

  actions do
    read :read do
      primary? true
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
    end

    # Every graduated token the public lists carry, on both chains.
    read :listed do
      prepare Autolaunch.Token.Preparations.ListedAuction
      prepare build(sort: [graduated_at: :desc, id: :asc], load: [:auction])
    end

    read :list_public do
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly

      prepare build(
                sort: [graduated_at: :desc, id: :asc],
                load: [:treasury_security_report, :auction]
              )
    end

    read :home_market do
      argument :x, :boolean, default: false
      argument :ens, :boolean, default: false
      argument :github, :boolean, default: false
      argument :query, :string, default: "", constraints: [allow_empty?: true, max_length: 80]
      argument :chain, :string, default: "all", constraints: [match: ~r/\A(all|base|robinhood)\z/]

      argument :kind, :string,
        default: "all",
        constraints: [match: ~r/\A(all|revstake|memestake)\z/]

      pagination keyset?: true, required?: true, default_limit: 24, max_page_size: 100
      prepare Autolaunch.Token.Preparations.ListedAuction

      # A query with a value the list does not know is refused as it stands.
      prepare fn
        %{valid?: false} = query, _context ->
          query

        query, _context ->
          query =
            case query.arguments.chain do
              "base" ->
                Ash.Query.filter(query, auction.chain_id == ^Autolaunch.Lab.chain_id())

              "robinhood" ->
                Ash.Query.filter(query, auction.chain_id == ^Autolaunch.Robinhood.Lab.chain_id())

              "all" ->
                query
            end

          query =
            case query.arguments.kind do
              "revstake" -> Ash.Query.filter(query, auction.kind == :agent)
              "memestake" -> Ash.Query.filter(query, auction.kind == :stocks)
              "all" -> query
            end

          query =
            if query.arguments.x,
              do:
                Ash.Query.filter(
                  query,
                  exists(auction.creator_x_connections, not is_nil(verified_at)) or
                    exists(auction.creator_identities, provider == :x)
                ),
              else: query

          query =
            if query.arguments.ens,
              do: Ash.Query.filter(query, exists(auction.creator_identities, provider == :ens)),
              else: query

          query =
            if query.arguments.github,
              do:
                Ash.Query.filter(query, exists(auction.creator_identities, provider == :github)),
              else: query

          query
          |> Ash.Query.load([:treasury_security_report, :auction])
          |> Autolaunch.Search.rank(query.arguments.query, graduated_at: :desc, id: :asc)
      end
    end

    read :top_public do
      filter expr(not is_nil(top_rank))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly

      prepare build(
                sort: [top_rank: :asc, id: :asc],
                limit: 12,
                load: [:treasury_security_report, :auction]
              )
    end

    read :recently_graduated_public do
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly

      prepare build(
                sort: [graduated_at: :desc, id: :asc],
                limit: 12,
                load: [:treasury_security_report, :auction]
              )
    end

    read :for_subject do
      argument :subject_id, :string,
        allow_nil?: false,
        constraints: SubjectIdentity.constraints()

      filter expr(subject_id == ^arg(:subject_id))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly

      prepare build(
                sort: [graduated_at: :desc, id: :asc],
                limit: 25,
                load: [:treasury_security_report, :auction]
              )
    end

    # A graduated Robinhood launch's token, named on its page by the token's
    # own address.
    read :robinhood_by_address do
      get? true
      argument :token_address, :string, allow_nil?: false
      prepare Autolaunch.Token.Preparations.ListedAuction
      prepare build(load: [:auction])

      prepare fn query, _context ->
        Ash.Query.filter(
          query,
          auction.chain_id == ^Autolaunch.Robinhood.Lab.chain_id() and
            auction.token_address == ^query.arguments.token_address
        )
      end
    end

    read :public_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
      prepare build(load: [:treasury_security_report, :auction])
    end

    # The projections' own read of an auction's token, beneath every listing
    # policy: a Robinhood launch made outside the site has a token too.
    read :projection_by_auction do
      get? true
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
    end

    # The graduated auction page links to its token's pool from here.
    read :public_by_auction do
      get? true
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
    end

    read :latest_price_for_subject do
      get? true

      argument :subject_id, :string,
        allow_nil?: false,
        constraints: SubjectIdentity.constraints()

      filter expr(subject_id == ^arg(:subject_id) and not is_nil(price_quote))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
      prepare build(sort: [price_updated_at: :desc, id: :desc], limit: 1)
    end

    create :project_lab do
      accept [
        :auction_id,
        :subject_id,
        :name,
        :symbol,
        :summary,
        :graduated_at,
        :top_rank,
        :treasury_address
      ]

      upsert? true
      upsert_identity :unique_auction

      upsert_fields [
        :subject_id,
        :name,
        :symbol,
        :summary,
        :graduated_at,
        :treasury_address
      ]
    end

    update :set_price_snapshot do
      require_atomic? false
      accept [:price_quote, :price_source, :price_updated_at]
    end

    # The listed token whose pool's trades are read next by
    # `Autolaunch.TokenTrades`, locked for the pass that claims it.
    read :trades_due do
      filter expr(is_nil(trades_due_at) or trades_due_at <= now())
      prepare Autolaunch.Token.Preparations.ListedAuction

      prepare build(
                sort: [trades_due_at: :asc_nils_first, id: :asc],
                limit: 1,
                load: [:auction],
                lock: :for_update
              )
    end

    # Not atomic: an atomic update re-reads through the primary read, which
    # hides Robinhood rows, so a Robinhood token would never be claimed.
    update :schedule_trades do
      require_atomic? false
      accept [:trades_due_at]
    end

    update :refresh_trades do
      require_atomic? false
      accept [:trades_next_block, :trades_last_hash, :trades_due_at]
    end
  end

  policies do
    policy action([
             :read,
             :listed,
             :list_public,
             :home_market,
             :top_public,
             :recently_graduated_public,
             :for_subject,
             :public_by_id,
             :robinhood_by_address,
             :public_by_auction,
             :latest_price_for_subject
           ]) do
      authorize_if always()
    end

    policy action([
             :project_lab,
             :projection_by_auction,
             :set_price_snapshot,
             :trades_due,
             :schedule_trades,
             :refresh_trades
           ]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  # A new token joins the public lists; see `Autolaunch.Listings`.
  pub_sub do
    module Phoenix.PubSub
    name Autolaunch.PubSub
    transform fn notification -> {:autolaunch_listings_changed, notification.data.auction_id} end

    publish_all :create, "listings"
  end

  attributes do
    uuid_primary_key :id

    # A token's name and symbol are its auction's, as the chain has them:
    # whatever an auction row admits, its token admits.
    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :symbol, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 16, trim?: true
    end

    attribute :summary, :string do
      public? true
      constraints max_length: 2_000, trim?: true
    end

    attribute :graduated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :top_rank, :integer do
      public? true
      constraints min: 1
    end

    attribute :subject_id, :string do
      public? true
      constraints SubjectIdentity.constraints()
    end

    attribute :price_quote, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :price_source, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :price_updated_at, :utc_datetime_usec do
      public? true
    end

    # Where `Autolaunch.TokenTrades` reads the pool's trades from next, the
    # hash of the block before it, and when the next pass is due.
    attribute :trades_next_block, :integer
    attribute :trades_last_hash, :string
    attribute :trades_due_at, :utc_datetime_usec

    attribute :treasury_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    timestamps()
  end

  relationships do
    # Read through the listing rule, so a Robinhood launch's token reaches its
    # auction too.
    belongs_to :auction, Autolaunch.Auction do
      read_action :listed
      allow_nil? false
      attribute_public? true
    end

    belongs_to :treasury_security_report,
               Autolaunch.TreasurySecurityReport do
      attribute_public? true
    end
  end

  calculations do
    # What every token is worth at its current price, in the pool currency's units.
    calculate :market_cap, :decimal, Autolaunch.Token.Calculations.MarketCap do
      public? true
    end

    # How closely a search matches this token: its auction's match, or its own
    # name and ticker; see `Autolaunch.Search`.
    calculate :search_rank,
              :float,
              expr(
                fragment(
                  "greatest(?, word_similarity(?, concat_ws(' ', ?, ?)))",
                  auction.search_rank(term: ^arg(:term), address: ^arg(:address)),
                  ^arg(:term),
                  name,
                  symbol
                )
              ) do
      argument :term, :string, allow_nil?: false
      argument :address, :string
    end
  end

  identities do
    identity :unique_auction, [:auction_id]
  end

  @doc "Returns the one public presentation shared by a graduated token and its auction."
  def presentation(token) do
    auction = loaded_auction(token)

    %{
      name: first_present(field(auction, :title), Map.get(token, :name)),
      symbol: first_present(field(auction, :token_symbol), Map.get(token, :symbol)),
      summary: first_present(field(auction, :summary), Map.get(token, :summary)),
      image: field(auction, :image),
      image_color: field(auction, :image_color),
      website: field(auction, :website),
      auction_address: field(auction, :auction_address)
    }
  end

  defp loaded_auction(%{auction: %Ash.NotLoaded{}}), do: nil
  defp loaded_auction(%{auction: auction}) when is_map(auction), do: auction
  defp loaded_auction(_token), do: nil

  defp field(nil, _key), do: nil
  defp field(record, key), do: Map.get(record, key)

  defp first_present(primary, fallback) when is_binary(primary) do
    if String.trim(primary) == "", do: fallback, else: primary
  end

  defp first_present(_primary, fallback), do: fallback
end
