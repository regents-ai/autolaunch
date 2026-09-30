defmodule AutolaunchWeb.Components.CreateNext do
  @moduledoc """
  The new Create page's launch plan, shown beside the form at /next/create and
  /next/create/revstake: where the supply goes, where the money goes, what the
  required raise means at the starting price, and the terms at a glance.

  Every figure is the deployed v1 contracts' rule: StocksPreset and
  StocksLaunchpadV1 (Memestake, on Base and Robinhood Chain alike) and
  RegentLBPStrategy (Revstake). The raise and valuation lines are plain
  arithmetic on what the creator typed; they are for reading, and the launch
  review still shows the exact values the wallet signs.
  """
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.FeeSchedule

  @floor_tip "The auction starts at a floor price and goes up over time, with each block clearing at the highest price where demand exceeds supply."

  # RegentLBPStrategy: FLOOR_PRICE_Q96 is one millionth of a REGENT per token,
  # START_DELAY_BLOCKS 300 and AUCTION_DURATION_BLOCKS 86,401.
  @revstake_floor "0.000001"
  @revstake_opens_blocks 300
  @revstake_length_blocks 86_401

  @supply %{
    memestake: %{
      total: 1_000_000_000,
      words: "1 billion",
      retires?: true,
      auction: 800_000_000,
      parts: [
        %{
          key: :auction,
          label: "Auction",
          amount: "800 million",
          share: 80,
          note: "Winning bidders claim what they bought. Unsold tokens are retired."
        },
        %{
          key: :pool,
          label: "Trading pool",
          amount: "200 million",
          share: 20,
          note:
            "Paired with the stock raised and locked forever. Any the pool does not use is retired."
        },
        %{
          key: :creator,
          label: "Creator, team or treasury",
          amount: "None",
          share: 0,
          note: "No tokens are set aside for anyone."
        }
      ]
    },
    revstake: %{
      total: 100_000_000_000,
      words: "100 billion",
      retires?: false,
      auction: 10_000_000_000,
      parts: [
        %{
          key: :auction,
          label: "Auction",
          amount: "10 billion",
          share: 10,
          note: "Winning bidders claim what they bought."
        },
        %{
          key: :pool,
          label: "Trading pool",
          amount: "5 billion",
          share: 5,
          note: "Paired with REGENT raised and locked forever."
        },
        %{
          key: :creator,
          label: "Your treasury",
          amount: "85 billion",
          share: 85,
          note:
            "Released over 365 days after a successful auction, with any unsold auction tokens and unused pool tokens."
        }
      ]
    }
  }

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:memestake, :revstake]
  attr :chain, :atom, default: :base
  attr :ticker, :string, required: true
  attr :currency, :string, default: nil, doc: "the stock's symbol, or nil before one is chosen"
  attr :floor, :string, default: "", doc: "the starting price per token, as typed"
  attr :raise, :string, default: "", doc: "the required raise, as typed"
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
      <.raise_bridge
        id={"#{@id}-bridge"}
        kind={@kind}
        supply={@supply}
        ticker={@ticker}
        unit={@unit}
        floor={if @kind == :revstake, do: revstake_floor(), else: @floor}
        raise={@raise}
      />
      <.terms_digest
        id={"#{@id}-terms"}
        kind={@kind}
        supply={@supply}
        chosen={@chosen}
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
          :if={part.share > 0}
          class={"create-next__bar-part create-next__part--#{part.key}"}
          style={"width: #{part.share}%"}
        ></span>
      </div>
      <p :if={@supply.retires?} class="create-next__note">
        Retired tokens are sent to an address nobody controls, so they can never be sold. The total
        supply does not change.
      </p>
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
              Paired with the 200 million pool tokens at the final auction price. The rest is added
              to the pool as {@unit} on its own.
            </span>
          </li>
          <li class="create-next__part create-next__part--creator">
            <span class="create-next__part-head">
              <span>You, the creator</span>
              <strong>None</strong>
            </span>
            <span class="create-next__part-note">There is no launch fee.</span>
          </li>
        </ul>
        <ul :if={@kind == :revstake} class="create-next__parts">
          <li class="create-next__part create-next__part--pool">
            <span class="create-next__part-head">
              <span>Trading pool, locked forever</span>
              <strong>Its share</strong>
            </span>
            <span class="create-next__part-note">
              The REGENT that matches the 5 billion pool tokens at the final auction price.
            </span>
          </li>
          <li class="create-next__part create-next__part--creator">
            <span class="create-next__part-head">
              <span>Your treasury</span>
              <strong>The rest</strong>
            </span>
            <span class="create-next__part-note">
              Every REGENT the pool does not take, as soon as the pool opens. There is no launch fee.
            </span>
          </li>
        </ul>
      </div>
      <p :if={@kind == :revstake} class="create-next__note">
        For example, if all 10 billion auction tokens sell for 20,000 REGENT and the auction ends at
        3 REGENT per 1M tokens, the pool takes 15,000 REGENT and your treasury receives 5,000 REGENT.
      </p>
      <p class="create-next__note">
        If the required raise is not reached, every bidder can withdraw their whole bid.
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
  attr :kind, :atom, required: true
  attr :supply, :map, required: true
  attr :ticker, :string, required: true
  attr :unit, :string, required: true
  attr :floor, :string, required: true
  attr :raise, :string, required: true

  defp raise_bridge(assigns) do
    assigns = assign(assigns, :bridge, bridge(assigns.supply, assigns.floor, assigns.raise))

    ~H"""
    <section id={@id} class="create-next__card" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="create-next__title">From required raise to valuation</h2>
      <p class="create-next__lead">
        Bidders set a total budget and a max price. Their budget is spread across the remaining
        blocks, like a TWAP, and buys tokens in every block that clears below their max price.
      </p>
      <p :if={@bridge == :waiting} class="create-next__note">
        Enter a starting price to see what the raise means at that price.
      </p>
      <dl :if={@bridge != :waiting} class="create-next__facts">
        <div>
          <dt>
            <.info_tip id={"#{@id}-floor-tip"} text={floor_tip()}>
              Starting price · per 1M {@ticker}
            </.info_tip>
          </dt>
          <dd>{show(@bridge.per_million)} {@unit}</dd>
        </div>
        <div>
          <dt>All {@supply.words} {@ticker} at the starting price</dt>
          <dd>{show(@bridge.start_value)} {@unit}</dd>
        </div>
        <div>
          <dt>Every auction token sold at the starting price</dt>
          <dd>{show(@bridge.auction_value)} {@unit}</dd>
        </div>
        <div :if={@bridge.raise}>
          <dt>Your required raise</dt>
          <dd>{show(@bridge.raise)} {@unit}</dd>
        </div>
      </dl>
      <p :if={@bridge != :waiting && @bridge.raise} class="create-next__result">
        {bridge_sentence(@bridge, @ticker, @unit)}
      </p>
      <p :if={@bridge != :waiting && !@bridge.raise} class="create-next__note">
        Set a required raise to see what it means at the starting price.
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
        <div :if={@kind == :revstake}>
          <dt>Starting price</dt>
          <dd>1 REGENT per 1M tokens</dd>
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

  # The arithmetic behind the bridge, on the starting price and raise as typed.
  # Nothing shows until the starting price is a positive number.
  defp bridge(supply, floor, raise) do
    case positive(floor) do
      nil ->
        :waiting

      floor ->
        %{
          floor: floor,
          per_million: Decimal.mult(floor, 1_000_000),
          start_value: Decimal.mult(floor, supply.total),
          auction_value: Decimal.mult(floor, supply.auction),
          auction: supply.auction,
          total: supply.total,
          raise: positive(raise)
        }
    end
  end

  defp bridge_sentence(bridge, ticker, unit) do
    if Decimal.compare(bridge.raise, bridge.auction_value) == :gt do
      average = Decimal.div(bridge.raise, bridge.auction)

      "Your required raise is more than every auction token sold at the starting price. " <>
        "Bids must reach an average of at least #{show(Decimal.mult(average, 1_000_000))} #{unit} " <>
        "per 1M #{ticker} to reach it, a valuation of #{show(Decimal.mult(average, bridge.total))} #{unit}."
    else
      tokens = Decimal.div(bridge.raise, bridge.floor)
      share = tokens |> Decimal.div(bridge.auction) |> Decimal.mult(100)

      "At the starting price, your required raise buys #{show(tokens)} #{ticker}, " <>
        "#{show(share)}% of the auction. Reaching it does not mean the auction sold out."
    end
  end

  defp positive(value) when is_binary(value) do
    case Decimal.cast(String.trim(value)) do
      {:ok, decimal} -> if Decimal.gt?(decimal, 0), do: decimal
      :error -> nil
    end
  end

  # Whole numbers keep two decimal places, small ones four significant
  # digits; either way the shown figure is never above the exact one.
  defp show(decimal) do
    places =
      if Decimal.compare(decimal, 1) == :lt,
        do: leading_zeros(decimal) + 4,
        else: 2

    decimal
    |> Decimal.round(places, :down)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> Autolaunch.Stocks.Amounts.grouped()
  end

  defp leading_zeros(decimal) do
    [_whole, fraction] =
      decimal |> Decimal.normalize() |> Decimal.to_string(:normal) |> String.split(".")

    byte_size(fraction) - byte_size(String.trim_leading(fraction, "0"))
  end

  defp fees(:memestake, chain) do
    for lane <- FeeSchedule.lanes(chain) do
      %{
        label: lane.label,
        rate: lane.rate,
        width: fee_width(lane.rate),
        note: "Of #{FeeSchedule.charged_on(lane.charged_on)}, to #{lane.receiver}."
      }
    end
  end

  # RegentFeeHook and the pool key RegentLBPStrategy fixes (POOL_FEE 3000).
  defp fees(:revstake, _chain) do
    [
      %{label: "Regent", rate: "1%", width: 100, note: "Of every trade, sent to Regent."},
      %{
        label: "Token stakers",
        rate: "1%",
        width: 100,
        note: "Of every trade, added to the token's staking rewards."
      },
      %{
        label: "Pool fee",
        rate: "0.3%",
        width: 30,
        note: "What the locked liquidity earns is added to the token's staking rewards."
      }
    ]
  end

  defp fee_width(rate) do
    {percent, "%"} = Float.parse(rate)
    round(min(percent, 1.0) * 100)
  end

  defp revstake_floor, do: @revstake_floor
  defp floor_tip, do: @floor_tip

  defp revstake_schedule,
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
