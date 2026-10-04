defmodule AutolaunchWeb.Components.CreateNext do
  @moduledoc """
  The new Create page's launch plan, shown beside the form at /next/create and
  /next/create/revstake: where the supply goes, where the money goes, how the
  auction opens, and the terms at a glance.

  Every figure is the launch type's fixed profile from the 1 October contracts:
  StocksPreset and RobinhoodPreset (Memestake, on Base and Robinhood Chain
  alike) and RegentLBPStrategy (Revstake). The creator chooses none of them; the
  launch review still shows the exact values the wallet signs.
  """
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.FeeSchedule

  @floor_tip "The auction starts at a floor price and goes up over time, with each block clearing at the highest price where demand exceeds supply."

  # RegentLBPStrategy: START_DELAY_BLOCKS 300 and AUCTION_DURATION_BLOCKS 86,401.
  @revstake_opens_blocks 300
  @revstake_length_blocks 86_401

  @supply %{
    memestake: %{
      words: "1 billion",
      parts: [
        %{
          key: :auction,
          label: "Auction",
          amount: "495 million",
          share: 49.5,
          note: "Winning bidders claim what they bought."
        },
        %{
          key: :pool,
          label: "Trading pool",
          amount: "495 million",
          share: 49.5,
          note:
            "Paired with everything the auction raised at its final price. The rest is a second position holding only the token. Both are locked forever."
        },
        %{
          key: :creator,
          label: "You, the creator",
          amount: "10 million",
          share: 1,
          note:
            "Released to you block by block over 30 days from when the pool opens. Anyone can send the release, and it always pays you."
        }
      ]
    },
    revstake: %{
      words: "100 billion",
      parts: [
        %{
          key: :auction,
          label: "Auction",
          amount: "20 billion",
          share: 20,
          note: "Winning bidders claim what they bought."
        },
        %{
          key: :pool,
          label: "Trading pool",
          amount: "Up to 10 billion",
          share: 10,
          note: "Paired with up to half the REGENT raised and locked forever."
        },
        %{
          key: :creator,
          label: "Your treasury",
          amount: "70 billion",
          share: 70,
          note:
            "Released over 365 days after a successful auction, with any pool tokens the pool did not take."
        }
      ]
    }
  }

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:memestake, :revstake]
  attr :chain, :atom, default: :base
  attr :ticker, :string, required: true
  attr :currency, :string, default: nil, doc: "the stock's symbol, or nil before one is chosen"
  attr :minimum, :string, required: true, doc: "the minimum raise, in words"
  attr :chosen, :list, required: true, doc: "{label, value} rows the creator sets"
  attr :schedule, :map, default: nil, doc: "Memestake's opens and length, in words"

  @doc "The four cards of the launch plan, in reading order."
  def launch_plan(assigns) do
    assigns =
      assign(assigns,
        supply: Map.fetch!(@supply, assigns.kind),
        unit: assigns.currency || default_unit(assigns.kind)
      )

    ~H"""
    <div id={@id} class="create-next">
      <.supply_map id={"#{@id}-supply"} supply={@supply} ticker={@ticker} />
      <.money_map id={"#{@id}-money"} kind={@kind} chain={@chain} unit={@unit} />
      <.auction_card id={"#{@id}-auction"} minimum={@minimum} />
      <.terms_digest
        id={"#{@id}-terms"}
        kind={@kind}
        supply={@supply}
        chosen={@chosen}
        minimum={@minimum}
        schedule={@schedule || revstake_schedule()}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :supply, :map, required: true
  attr :ticker, :string, required: true

  defp supply_map(assigns) do
    ~H"""
    <section id={@id} class="create-next__card" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="create-next__title">Where the supply goes</h2>
      <div class="create-next__flow">
        <div class="create-next__source">
          <span>Minted once</span>
          <strong>{@supply.words}</strong>
          <span>{@ticker}</span>
        </div>
        <ul class="create-next__parts">
          <li :for={part <- @supply.parts} class={"create-next__part create-next__part--#{part.key}"}>
            <span class="create-next__part-head">
              <span>{part.label}</span>
              <strong>{part.amount}</strong>
            </span>
            <span class="create-next__part-note">{part.note}</span>
          </li>
        </ul>
      </div>
      <div class="create-next__bar" aria-hidden="true">
        <span
          :for={part <- @supply.parts}
          class={"create-next__bar-part create-next__part--#{part.key}"}
          style={"width: #{part.share}%"}
        ></span>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :chain, :atom, required: true
  attr :unit, :string, required: true

  defp money_map(assigns) do
    assigns = assign(assigns, :fees, fees(assigns.kind, assigns.chain))

    ~H"""
    <section id={@id} class="create-next__card" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="create-next__title">Where the money goes</h2>
      <div class="create-next__flow">
        <div class="create-next__source">
          <span>Everything the auction raises</span>
          <strong>{@unit}</strong>
        </div>
        <ul :if={@kind == :memestake} class="create-next__parts">
          <li class="create-next__part create-next__part--pool">
            <span class="create-next__part-head">
              <span>Trading pool, locked forever</span>
              <strong>All of it</strong>
            </span>
            <span class="create-next__part-note">
              Paired with the pool tokens at the final auction price.
            </span>
          </li>
          <li class="create-next__part create-next__part--creator">
            <span class="create-next__part-head">
              <span>You, the creator</span>
              <strong>None</strong>
            </span>
            <span class="create-next__part-note">
              There is no launch fee. You earn a share of every trade instead.
            </span>
          </li>
        </ul>
        <ul :if={@kind == :revstake} class="create-next__parts">
          <li class="create-next__part create-next__part--pool">
            <span class="create-next__part-head">
              <span>Trading pool, locked forever</span>
              <strong>Up to half</strong>
            </span>
            <span class="create-next__part-note">
              Paired with the pool tokens at the final auction price.
            </span>
          </li>
          <li class="create-next__part create-next__part--creator">
            <span class="create-next__part-head">
              <span>Your treasury</span>
              <strong>At least half</strong>
            </span>
            <span class="create-next__part-note">
              Every REGENT the pool does not take, as soon as the pool opens. There is no launch fee.
            </span>
          </li>
        </ul>
      </div>
      <p :if={@kind == :revstake} class="create-next__note">
        For example, if the auction raises 20,000 REGENT, the pool takes up to 10,000 REGENT and your
        treasury receives at least 10,000 REGENT.
      </p>

      <h3 class="create-next__subtitle">Every trade after launch</h3>
      <ul class="create-next__fees">
        <li :for={fee <- @fees}>
          <span>{fee.label}</span>
          <span class="create-next__fee-track" aria-hidden="true">
            <span style={"width: #{fee.width}%"}></span>
          </span>
          <strong>{fee.rate}</strong>
          <span class="create-next__part-note">{fee.note}</span>
        </li>
      </ul>
      <p class="create-next__note">
        Regent keeps 2% of the token's staking rewards. It is not another trading fee.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :minimum, :string, required: true

  defp auction_card(assigns) do
    assigns = assign(assigns, :floor_tip, @floor_tip)

    ~H"""
    <section id={@id} class="create-next__card" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="create-next__title">How the auction runs</h2>
      <p class="create-next__lead">
        Bidders set a total budget and a max price. Their budget is spread across the remaining
        blocks, like a TWAP, and buys tokens in every block that clears below their max price.
      </p>
      <dl class="create-next__facts">
        <div>
          <dt>
            <.info_tip id={"#{@id}-floor-tip"} text={@floor_tip}>Starting price</.info_tip>
          </dt>
          <dd>The lowest the auction accepts</dd>
        </div>
        <div>
          <dt>Minimum raise</dt>
          <dd>{@minimum}</dd>
        </div>
      </dl>
      <p class="create-next__note">
        A successful auction sells every auction token. If bids stay under the minimum, every bidder
        takes back their whole bid and every token is burned.
      </p>
      <p class="create-next__note">
        <.link navigate={~p"/how-it-works#how-it-works-auction"}>How the auction works</.link>
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :supply, :map, required: true
  attr :chosen, :list, required: true
  attr :minimum, :string, required: true
  attr :schedule, :map, required: true

  defp terms_digest(assigns) do
    ~H"""
    <section id={@id} class="create-next__card" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="create-next__title">Your terms at a glance</h2>
      <h3 class="create-next__subtitle">You choose</h3>
      <dl class="create-next__facts">
        <div :for={{label, value} <- @chosen}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
      <h3 class="create-next__subtitle">The same for every {kind_label(@kind)} launch</h3>
      <dl class="create-next__facts">
        <div>
          <dt>Supply</dt>
          <dd>{@supply.words}</dd>
        </div>
        <div>
          <dt>Auction · pool · {creator_label(@kind)}</dt>
          <dd>{Enum.map_join(@supply.parts, " · ", &"#{&1.share}%")}</dd>
        </div>
        <div>
          <dt>Starting price</dt>
          <dd>The lowest the auction accepts</dd>
        </div>
        <div>
          <dt>Minimum raise</dt>
          <dd>{@minimum}</dd>
        </div>
        <div>
          <dt>Bidding opens</dt>
          <dd>{@schedule.opens} after launch</dd>
        </div>
        <div>
          <dt>Auction length</dt>
          <dd>{@schedule.length}</dd>
        </div>
        <div>
          <dt>Pool liquidity</dt>
          <dd>Locked forever</dd>
        </div>
        <div>
          <dt>Launch fee</dt>
          <dd>None</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp fees(:memestake, chain) do
    lanes = FeeSchedule.lanes(chain, :v2)

    lanes
    |> Enum.map(fn lane ->
      %{
        label: lane.label,
        rate: lane.rate,
        percent: rate_percent(lane.rate),
        note: "Of #{FeeSchedule.charged_on(lane.charged_on)}, to #{lane.receiver}."
      }
    end)
    |> with_widths()
  end

  # RegentFeeHook's two lanes and the pool key RegentLBPStrategy fixes (POOL_FEE 3000).
  defp fees(:revstake, _chain) do
    with_widths([
      %{label: "Regent", rate: "1.00%", percent: 1.0, note: "Of every trade, to REGENT staking."},
      %{
        label: "Token stakers",
        rate: "2.00%",
        percent: 2.0,
        note: "Of every trade, added to the token's staking rewards."
      },
      %{
        label: "Pool fee",
        rate: "0.30%",
        percent: 0.3,
        note: "What the locked liquidity earns is added to the token's staking rewards."
      }
    ])
  end

  # Each bar is drawn against the largest fee, so the largest fills its track.
  defp with_widths(fees) do
    largest = fees |> Enum.map(& &1.percent) |> Enum.max()
    Enum.map(fees, &Map.put(&1, :width, round(&1.percent / largest * 100)))
  end

  defp rate_percent(rate) do
    {percent, "%"} = Float.parse(rate)
    percent
  end

  @doc "When a Revstake auction opens and how long it runs, in words."
  def revstake_schedule,
    do: %{
      opens: LaunchChain.time_estimate(:base, @revstake_opens_blocks),
      length: LaunchChain.time_estimate(:base, @revstake_length_blocks)
    }

  defp default_unit(:memestake), do: "the stock"
  defp default_unit(:revstake), do: "REGENT"

  defp kind_label(:memestake), do: "Memestake"
  defp kind_label(:revstake), do: "Revstake"

  defp creator_label(:memestake), do: "creator"
  defp creator_label(:revstake), do: "treasury"
end
