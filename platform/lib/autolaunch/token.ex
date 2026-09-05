defmodule Autolaunch.Token do
  alias Autolaunch.SubjectIdentity

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  require Ash.Query

  postgres do
    table "tokens"
    repo Autolaunch.Repo
  end

  actions do
    read :read do
      primary? true
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
    end

    read :list_public do
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly

      prepare build(
                sort: [graduated_at: :desc, id: :asc],
                load: [:treasury_security_report, :auction]
              )
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

    read :graduated_launchpad do
      argument :query, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, max_length: 80]

      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
      prepare fn query, _context -> launchpad_query(query, 8) end
    end

    read :explore_launchpad do
      argument :query, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, max_length: 80]

      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
      prepare fn query, _context -> launchpad_query(query, 24) end
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

    read :public_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare Autolaunch.Token.Preparations.SiteCreatedAuctionOnly
      prepare build(load: [:treasury_security_report, :auction])
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
  end

  policies do
    policy action([
             :read,
             :list_public,
             :top_public,
             :recently_graduated_public,
             :graduated_launchpad,
             :explore_launchpad,
             :for_subject,
             :public_by_id,
             :latest_price_for_subject
           ]) do
      authorize_if always()
    end

    policy action([:project_lab, :set_price_snapshot]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :symbol, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 16, match: ~r/\A[A-Z0-9]+\z/
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

    attribute :treasury_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    timestamps()
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      attribute_public? true
    end

    belongs_to :treasury_security_report,
               Autolaunch.TreasurySecurityReport do
      attribute_public? true
    end
  end

  identities do
    identity :unique_auction, [:auction_id]
  end

  defp launchpad_query(query, limit) do
    term = query.arguments.query |> String.trim() |> String.downcase()
    pattern = literal_search_pattern(term)

    query
    |> launchpad_search_filter(term, pattern)
    |> Ash.Query.sort(graduated_at: :desc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([:treasury_security_report, :auction])
  end

  defp launchpad_search_filter(query, "", _pattern), do: query

  # One SQL predicate keeps auction-first fallback semantics identical for every search field.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp launchpad_search_filter(query, _term, pattern) do
    Ash.Query.filter(
      query,
      ilike(auction.title, ^pattern) or
        ((is_nil(auction.token_symbol) or auction.token_symbol == "") and
           ilike(symbol, ^pattern)) or
        (not is_nil(auction.token_symbol) and auction.token_symbol != "" and
           ilike(auction.token_symbol, ^pattern)) or
        ((is_nil(auction.summary) or auction.summary == "") and ilike(summary, ^pattern)) or
        (not is_nil(auction.summary) and auction.summary != "" and
           ilike(auction.summary, ^pattern)) or
        ilike(auction.auction_address, ^pattern) or
        exists(
          [:auction, :creator_x_connections],
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

  @doc "Returns the one public presentation shared by a graduated token and its auction."
  def presentation(token) do
    auction = loaded_auction(token)

    %{
      name: first_present(field(auction, :title), Map.get(token, :name)),
      symbol: first_present(field(auction, :token_symbol), Map.get(token, :symbol)),
      summary: first_present(field(auction, :summary), Map.get(token, :summary)),
      image: field(auction, :image),
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
