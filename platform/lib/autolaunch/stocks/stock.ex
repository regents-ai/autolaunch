defmodule Autolaunch.Stocks.Stock do
  @moduledoc """
  A stock token the site supports as a launch currency, one row per chain and
  token address, so search can find an auction by the stock it trades in.

  `Autolaunch.Stocks.SupportedStocks` records every stock the chains' lists
  offer when the site starts. Its ticker and company name follow those lists;
  its search words start from a set kept here and are ours to change after
  that with `:set_search_words`. A stock that leaves the lists keeps its row,
  so auctions already trading in it stay findable by its name.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Other names people search for, by plain ticker.
  @starting_words %{
    "AAPL" => ["Apple Inc", "iPhone"],
    "AMD" => ["Advanced Micro Devices"],
    "AMZN" => ["Amazon.com", "AWS"],
    "BABA" => ["Alibaba"],
    "COIN" => ["Coinbase"],
    "CRCL" => ["Circle", "USDC"],
    "DELL" => ["Dell Technologies"],
    "GME" => ["GameStop"],
    "GOOGL" => ["Alphabet", "Google"],
    "INTC" => ["Intel"],
    "META" => ["Meta Platforms", "Facebook", "Instagram"],
    "MSFT" => ["Microsoft"],
    "MSTR" => ["Strategy", "MicroStrategy"],
    "MU" => ["Micron Technology"],
    "NVDA" => ["NVIDIA"],
    "PLTR" => ["Palantir"],
    "QQQ" => ["Nasdaq 100", "Invesco QQQ"],
    "SGOV" => ["Treasury bills", "T-bills"],
    "SLV" => ["Silver", "iShares Silver Trust"],
    "SNDK" => ["Sandisk"],
    "SPCX" => ["SpaceX"],
    "SPY" => ["S&P 500", "SPDR"],
    "TSLA" => ["Tesla"],
    "TSM" => ["TSMC", "Taiwan Semiconductor"],
    "USAR" => ["USA Rare Earth"],
    "USO" => ["Oil", "United States Oil Fund"]
  }

  postgres do
    table "stocks"
    repo Autolaunch.Repo
  end

  actions do
    defaults [:read]

    # Recorded again on every start; the search words set when the row was
    # first written are left alone.
    create :record_supported do
      accept [:chain_id, :address, :symbol, :name]
      upsert? true
      upsert_identity :chain_address
      upsert_fields [:symbol, :name]

      change fn changeset, _context ->
        ticker =
          changeset
          |> Ash.Changeset.get_attribute(:symbol)
          |> Autolaunch.Stocks.PriceFeeds.ticker()

        Ash.Changeset.force_change_attribute(changeset, :search_words, starting_words(ticker))
      end
    end

    update :set_search_words do
      accept [:search_words]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:record_supported, :set_search_words]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, public?: true

    attribute :address, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A0x[0-9a-fA-F]{40}\z/]

    attribute :symbol, :string, allow_nil?: false, public?: true, constraints: [max_length: 32]
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 120]

    attribute :search_words, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [max_length: 80]]

    timestamps()
  end

  calculations do
    # Every name the stock goes by, for search.
    calculate :search_text,
              :string,
              expr(
                fragment(
                  "concat_ws(' ', ?, ?, array_to_string(?, ' '))",
                  symbol,
                  name,
                  search_words
                )
              )
  end

  identities do
    identity :chain_address, [:chain_id, :address]
  end

  defp starting_words(ticker), do: Map.get(@starting_words, ticker, [])
end
