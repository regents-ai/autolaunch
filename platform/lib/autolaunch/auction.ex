defmodule Autolaunch.Auction do
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  alias Autolaunch.{BidActions, TreasurySecurity}
  alias Autolaunch.LabProjection
  require Ash.Query

  @projection_accept [
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
    :treasury_address
  ]

  @projection_upsert [
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
    :treasury_address
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

    read :list_public do
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(sort: [inserted_at: :desc, id: :asc], load: [:treasury_security_report])
    end

    read :page_public do
      argument :mode, :string,
        default: "all",
        constraints: [match: ~r/\A(all|biddable|live|failed_minimum|graduated)\z/]

      argument :sort, :string, default: "newest", constraints: [match: ~r/\A(newest|oldest)\z/]
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 50
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(load: [:treasury_security_report])

      prepare fn query, _context ->
        query =
          case Ash.Query.get_argument(query, :mode) do
            mode when mode in ["live", "biddable"] -> Ash.Query.filter(query, state == :active)
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
      prepare fn query, _context -> market_query(query, [:created, :active], 8) end
    end

    read :explore_launchpad do
      argument :query, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, max_length: 80]

      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare fn query, _context -> market_query(query, [:created, :active, :failed], 24) end
    end

    read :public_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Auction.Preparations.SiteCreatedOnly
      prepare build(load: [:treasury_security_report])
    end

    read :watchable_lab do
      filter expr(not is_nil(auction_address))
      prepare build(sort: [id: :asc])

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, records ->
          {:ok,
           records
           |> Enum.filter(fn record ->
             record.id == LabProjection.auction_id(record.auction_address)
           end)
           |> Enum.take(257)}
        end)
      end
    end

    read :lab_by_id_for_update do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and not is_nil(auction_address))

      prepare fn query, _context ->
        query
        |> Ash.Query.lock(:for_update)
        |> Ash.Query.after_action(fn _query, records ->
          {:ok,
           Enum.filter(records, fn record ->
             record.id == LabProjection.auction_id(record.auction_address)
           end)}
        end)
      end
    end

    create :project_lab do
      argument :projection_id, :uuid, allow_nil?: false
      accept @projection_accept
      change set_attribute(:id, arg(:projection_id))
      upsert? true
      upsert_fields @projection_upsert
    end

    create :project_launch do
      argument :projection_id, :uuid, allow_nil?: false
      accept @projection_accept
      change set_attribute(:id, arg(:projection_id))
      upsert? true
      upsert_fields @projection_upsert
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
      accept [:state, :current_clearing_price]
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

    action :claim_bid_dispatch, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.claim_dispatch(input, context) end
    end

    # The step travels with the hash so a callback the browser replays after a
    # reload cannot be bound to whatever step the operation has since reached.
    action :bind_bid_hash, :map do
      argument :action_id, :string, allow_nil?: false

      argument :step, :atom,
        allow_nil?: false,
        constraints: [one_of: [:token_approval, :permit2_approval, :bid]]

      argument :transaction_hash, :string, allow_nil?: false
      run fn input, context -> BidActions.bind_hash(input, context) end
    end

    action :verify_bid_step, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.verify(input, context) end
    end

    action :cancel_bid_review, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.cancel(input, context) end
    end

    action :close_bid_not_sent, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.close_not_sent(input, context) end
    end

    action :release_unstarted_bid_dispatch, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.release_unstarted(input, context) end
    end

    action :start_new_bid, :map do
      argument :action_id, :string, allow_nil?: false
      run fn input, context -> BidActions.start_new_bid(input, context) end
    end

    action :open_bid_operation, :map do
      run fn input, context -> BidActions.open_operation(input, context) end
    end
  end

  policies do
    policy action([
             :read,
             :list_public,
             :page_public,
             :recent_public,
             :featured_public,
             :active_launchpad,
             :explore_launchpad,
             :public_by_id
           ]) do
      authorize_if always()
    end

    policy action([
             :project_lab,
             :project_launch,
             :watchable_lab,
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
             :claim_bid_dispatch,
             :bind_bid_hash,
             :verify_bid_step,
             :cancel_bid_review,
             :close_bid_not_sent,
             :release_unstarted_bid_dispatch,
             :start_new_bid,
             :open_bid_operation
           ]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
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

    attribute :featured, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :created
      constraints one_of: [:created, :active, :graduated, :failed]
    end

    attribute :opened_at, :utc_datetime_usec do
      public? true
    end

    attribute :auction_address, :string do
      public? true
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

    timestamps()
  end

  relationships do
    belongs_to :creator_human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
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
end
