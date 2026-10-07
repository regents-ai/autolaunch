defmodule AutolaunchWeb.Components.RegentNext do
  @moduledoc """
  The pieces of the REGENT page (`/regent`), all drawn from the one
  shared `Autolaunch.RegentFacts` reading of REGENT staking on Base:

    * `deposit_allocation/1` - every USDC deposit since staking opened, as
      the contract split it between stakers and Regent's treasury;
    * `deposits_by_source/1` - the last seven days of deposits, grouped by
      the source each depositor recorded;
    * `next_split/1` - how the next deposit would split with the stake as it
      is now;
    * `memestake_sources/1` - Memestake's two lanes to REGENT stakers, each
      stage in its own asset, the Robinhood Chain USDG never added to USDC;
    * `emissions/1` - REGENT emissions, a stream apart from the USDC.

  The staking contract credits stakers each deposit times the REGENT staked
  over its fixed count of all REGENT; the rest goes to Regent's treasury.
  Every figure names the Base block it was read at or says it is worked out;
  a figure that could not be read says so.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.{Amounts, FeeSchedule}
  alias AutolaunchWeb.TokenDisplay

  attr :facts, :map, required: true

  @doc "Every USDC deposit since staking opened, split between stakers and the treasury."
  def deposit_allocation(assigns) do
    assigns =
      assign(assigns,
        block: block(assigns.facts),
        parts:
          parts(
            assigns.facts.usdc_received_lifetime,
            assigns.facts.usdc_credited_lifetime,
            assigns.facts.usdc_treasury_lifetime
          )
      )

    ~H"""
    <section
      id="regent-next-allocation"
      class="regent-next-card"
      aria-labelledby="regent-next-allocation-title"
    >
      <header class="regent-next-card__head">
        <h2 id="regent-next-allocation-title">Where the USDC went</h2>
        <span class="regent-next-tag">Since staking opened</span>
      </header>
      <p class="regent-next-lead">
        Every USDC deposit is split when it arrives. Only the stakers' part is staking rewards.
      </p>
      <dl class="regent-next-figures">
        <div>
          <dt>Received</dt>
          <dd>{usdc(@facts.usdc_received_lifetime)}</dd>
          <small>Every deposit into REGENT staking.</small>
        </div>
        <div>
          <dt>Credited to stakers</dt>
          <dd class="regent-next-figures__stakers">{usdc(@facts.usdc_credited_lifetime)}</dd>
          <small>Shared by everyone staked when each deposit arrived.</small>
        </div>
        <div>
          <dt>To Regent's treasury</dt>
          <dd>{usdc(@facts.usdc_treasury_lifetime)}</dd>
          <small>Received less what was credited to stakers.</small>
        </div>
      </dl>
      <.split_bar :if={@parts} id="regent-next-allocation" parts={@parts} />
      <p class="regent-next-source">
        Received and credited read from the staking contract at Base block {@block}; the treasury
        figure is worked out from them.
      </p>
    </section>
    """
  end

  attr :facts, :map, required: true

  @doc """
  The last seven days of deposits, each source as the depositor recorded it.
  A tag this page does not know is shown as written or left unattributed,
  never given a product name.
  """
  def deposits_by_source(%{facts: %{deposits_7d: :unavailable}} = assigns) do
    ~H"""
    <section
      id="regent-next-sources"
      class="regent-next-card"
      aria-labelledby="regent-next-sources-title"
    >
      <header class="regent-next-card__head">
        <h2 id="regent-next-sources-title">The last seven days, by source</h2>
      </header>
      <p class="regent-next-muted">
        Unavailable: the deposit history could not be read just now. The totals above still stand.
      </p>
    </section>
    """
  end

  def deposits_by_source(assigns) do
    deposits = assigns.facts.deposits_7d

    assigns =
      assign(assigns,
        deposits: deposits,
        from: grouped(deposits.from_block),
        to: grouped(deposits.to_block),
        parts: parts(deposits.total.received, deposits.total.stakers, deposits.total.treasury)
      )

    ~H"""
    <section
      id="regent-next-sources"
      class="regent-next-card"
      aria-labelledby="regent-next-sources-title"
    >
      <header class="regent-next-card__head">
        <h2 id="regent-next-sources-title">The last seven days, by source</h2>
        <span class="regent-next-tag">USDC only</span>
      </header>
      <p class="regent-next-lead">
        {deposit_count(@deposits.count)} recorded in the last {grouped(@facts.window_blocks)} Base blocks,
        about seven days: blocks {@from} to {@to}.
      </p>
      <table class="regent-next-table">
        <thead>
          <tr>
            <th scope="col">Source</th>
            <th scope="col" class="regent-next-table__amount">Received</th>
            <th scope="col" class="regent-next-table__amount">To stakers</th>
            <th scope="col" class="regent-next-table__amount">To treasury</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{source, allocation} <- @deposits.sources}>
            <th scope="row">
              {source_name(source)}
              <small>{source_note(source)}</small>
            </th>
            <td data-label="Received" class="regent-next-table__amount">
              {usdc(allocation.received)}
            </td>
            <td data-label="To stakers" class="regent-next-table__amount">
              {usdc(allocation.stakers)}
            </td>
            <td data-label="To treasury" class="regent-next-table__amount">
              {usdc(allocation.treasury)}
            </td>
          </tr>
        </tbody>
        <tfoot>
          <tr>
            <th scope="row">All deposits</th>
            <td data-label="Received" class="regent-next-table__amount">
              {usdc(@deposits.total.received)}
            </td>
            <td data-label="To stakers" class="regent-next-table__amount">
              {usdc(@deposits.total.stakers)}
            </td>
            <td data-label="To treasury" class="regent-next-table__amount">
              {usdc(@deposits.total.treasury)}
            </td>
          </tr>
        </tfoot>
      </table>
      <.split_bar :if={@parts} id="regent-next-sources" parts={@parts} />
      <p class="regent-next-source">
        Each deposit's split as the staking contract recorded it, added up from its own records at
        Base block {@to}. The window is counted in blocks, not clock time. A source is named only
        from the tag its depositor recorded.
      </p>
    </section>
    """
  end

  attr :facts, :map, required: true

  @doc "How the next deposit would split with the stake as it is now."
  def next_split(%{facts: %{staked_denominator_share: :unavailable}} = assigns) do
    ~H"""
    <section id="regent-next-split" class="regent-next-card" aria-labelledby="regent-next-split-title">
      <header class="regent-next-card__head">
        <h2 id="regent-next-split-title">How the next deposit splits</h2>
      </header>
      <p>
        Stakers share the USDC paid into staking. Each staker's cut is their share of all REGENT.
      </p>
      <p class="regent-next-muted">
        Unavailable: the staking contract's count of all REGENT could not be read.
      </p>
    </section>
    """
  end

  def next_split(assigns) do
    stakers = assigns.facts.staked_denominator_share

    assigns =
      assign(assigns,
        block: block(assigns.facts),
        staked: percent(stakers),
        parts: [
          %{key: :stakers, label: "Stakers", share: stakers},
          %{key: :treasury, label: "Regent's treasury", share: Decimal.sub(1, stakers)}
        ]
      )

    ~H"""
    <section id="regent-next-split" class="regent-next-card" aria-labelledby="regent-next-split-title">
      <header class="regent-next-card__head">
        <h2 id="regent-next-split-title">How the next deposit splits</h2>
        <span class="regent-next-tag">Right now</span>
      </header>
      <p>
        Stakers share the USDC paid into staking. Each staker's cut is their share of all REGENT.
      </p>
      <p>
        <TokenDisplay.amount amount={@facts.total_staked} unit="REGENT" /> is staked, of the
        <TokenDisplay.amount amount={@facts.revenue_share_denominator} unit="REGENT" /> the staking
        contract counts as all REGENT. So the next deposit would go {@staked} to stakers and the
        rest to Regent's treasury.
      </p>
      <.split_bar id="regent-next-split" parts={@parts} />
      <p class="regent-next-source">
        Worked out from the stake read at Base block {@block}. This is a share of all REGENT, not of
        circulating REGENT, and it moves whenever anyone stakes or unstakes.
      </p>
    </section>
    """
  end

  attr :facts, :map, required: true
  attr :base_lane, Phoenix.LiveView.AsyncResult, required: true
  attr :robinhood_lane, Phoenix.LiveView.AsyncResult, required: true

  @doc """
  Memestake's lane to REGENT stakers on each chain, stage by stage, each in its
  own asset, with what each stage holds or has passed on now
  (`Autolaunch.MemestakeLanes`). Robinhood Chain's USDG is never counted as
  USDC; it becomes USDC only once it arrives on Base.
  """
  def memestake_sources(assigns) do
    assigns =
      assign(assigns,
        base_rate: FeeSchedule.lane(:base, :v2, :regent).rate,
        robinhood_rate: FeeSchedule.lane(:robinhood, :v2, :regent).rate,
        base_7d: source_received(assigns.facts, :memestake_base),
        robinhood_7d: source_received(assigns.facts, :robinhood)
      )

    ~H"""
    <section
      id="regent-next-memestake"
      class="regent-next-card"
      aria-labelledby="regent-next-memestake-title"
    >
      <header class="regent-next-card__head">
        <h2 id="regent-next-memestake-title">Memestake's share, chain by chain</h2>
      </header>
      <p class="regent-next-lead">
        Every Memestake trade pays a share of its stock side for REGENT stakers. Each chain's share
        moves through its own stages, in its own asset.
      </p>
      <div class="regent-next-lanes">
        <section class="regent-next-lane" aria-labelledby="regent-next-lane-base">
          <h3 id="regent-next-lane-base">On Base</h3>
          <ol class="regent-next-stages">
            <li>
              <strong>Charged on each trade</strong>
              <span>{@base_rate} of the stock side waits in the pool as the stock.</span>
              <.lane_line :let={lane} lane={@base_lane}>
                <.stocks label="Waiting now" amounts={lane.waiting} none="Nothing waiting now." />
              </.lane_line>
            </li>
            <li>
              <strong>Swapped to USDC and paid into REGENT staking</strong>
              <span>Regent's settling wallet does both in one step.</span>
              <.lane_line :let={lane} lane={@base_lane}>
                <.stocks
                  label="Swapped so far"
                  amounts={lane.converted}
                  none="Nothing swapped yet."
                  dollars={usdc(lane.paid_usdc)}
                />
              </.lane_line>
              <span :if={@base_7d}>{usdc(@base_7d)} paid in over the last seven days.</span>
              <span :if={!@base_7d} class="regent-next-muted">
                Unavailable: the deposit history could not be read just now.
              </span>
            </li>
          </ol>
        </section>
        <section class="regent-next-lane" aria-labelledby="regent-next-lane-robinhood">
          <h3 id="regent-next-lane-robinhood">On Robinhood Chain</h3>
          <ol class="regent-next-stages">
            <li>
              <strong>Charged on each trade</strong>
              <span>{@robinhood_rate} of the stock side waits in the pool as the stock.</span>
              <.lane_line :let={lane} lane={@robinhood_lane}>
                <.stocks label="Waiting now" amounts={lane.waiting} none="Nothing waiting now." />
              </.lane_line>
            </li>
            <li>
              <strong>Swapped to USDG, held on Robinhood Chain</strong>
              <span>
                It is held there as USDG until it moves to Base, and is not added to any USDC
                figure on this page.
              </span>
              <.lane_line :let={lane} lane={@robinhood_lane}>
                <.stocks
                  label="Swapped so far"
                  amounts={lane.converted}
                  none="Nothing swapped yet."
                  dollars={"#{dollars(lane.collected_usdg)} USDG"}
                />
              </.lane_line>
              <.lane_line :let={lane} lane={@robinhood_lane}>
                Held now: {dollars(lane.held_usdg)} USDG.
              </.lane_line>
            </li>
            <li>
              <strong>Moved to Base</strong>
              <.lane_line :let={lane} lane={@robinhood_lane}>
                <%= if lane.bridge == :not_set_up do %>
                  Not set up yet.
                <% else %>
                  Sent so far: {dollars(lane.bridge.sent_usdg)} USDG. Arrived, waiting to be paid
                  in: {usdc(lane.bridge.arrived_usdc)}.
                <% end %>
              </.lane_line>
            </li>
            <li>
              <strong>Paid into REGENT staking</strong>
              <.lane_line :let={lane} lane={@robinhood_lane}>
                <%= if lane.bridge == :not_set_up do %>
                  Nothing paid in yet.
                <% else %>
                  Paid in so far: {usdc(lane.bridge.paid_usdc)}.
                <% end %>
              </.lane_line>
              <span :if={@robinhood_7d}>
                {usdc(@robinhood_7d)} paid in over the last seven days.
              </span>
              <span :if={!@robinhood_7d} class="regent-next-muted">
                Unavailable: the deposit history could not be read just now.
              </span>
            </li>
          </ol>
        </section>
      </div>
      <p class="regent-next-source">
        Rates from the fee schedule every Memestake launch uses. Amounts paid in over seven days
        read from the staking contract's records at Base block {block(@facts)}.
        <.lane_blocks base_lane={@base_lane} robinhood_lane={@robinhood_lane} />
      </p>
    </section>
    """
  end

  attr :lane, Phoenix.LiveView.AsyncResult, required: true
  slot :inner_block, required: true

  # One line of a stage that reads the chain. It holds its place while the
  # reading is under way or did not answer, so the stages never change height.
  defp lane_line(assigns) do
    ~H"""
    <span :if={@lane.loading} class="regent-next-muted">Reading the chain…</span>
    <span :if={@lane.failed} class="regent-next-muted">Unavailable just now.</span>
    <span :if={@lane.ok? && @lane.result}>{render_slot(@inner_block, @lane.result)}</span>
    <span :if={@lane.ok? && !@lane.result} class="regent-next-muted">Not on this site.</span>
    """
  end

  attr :label, :string, required: true
  attr :amounts, :list, required: true
  attr :none, :string, required: true
  attr :dollars, :string, default: nil

  defp stocks(%{amounts: []} = assigns) do
    ~H"""
    {@none}
    """
  end

  defp stocks(assigns) do
    ~H"""
    {@label}:
    <%= for {stock, index} <- Enum.with_index(@amounts) do %>
      {if index > 0, do: ", "}<TokenDisplay.tokens amount={stock.amount} unit={stock.symbol} />
    <% end %>
    {if @dollars, do: ", for #{@dollars}"}.
    """
  end

  attr :base_lane, Phoenix.LiveView.AsyncResult, required: true
  attr :robinhood_lane, Phoenix.LiveView.AsyncResult, required: true

  defp lane_blocks(assigns) do
    ~H"""
    <%= case {@base_lane, @robinhood_lane} do %>
      <% {%{ok?: true, result: %{block: base}}, %{ok?: true, result: %{block: robinhood}}} -> %>
        Stage amounts read at Base block {grouped(base)} and Robinhood Chain block {grouped(robinhood)}.
      <% {%{ok?: true, result: %{block: base}}, _robinhood} -> %>
        Stage amounts on Base read at block {grouped(base)}.
      <% {_base, %{ok?: true, result: %{block: robinhood}}} -> %>
        Stage amounts on Robinhood Chain read at block {grouped(robinhood)}.
      <% _neither -> %>
    <% end %>
    """
  end

  attr :facts, :map, required: true

  @doc "REGENT emissions: paid in REGENT, apart from every USDC figure."
  def emissions(assigns) do
    ~H"""
    <section
      id="regent-next-emissions"
      class="regent-next-card"
      aria-labelledby="regent-next-emissions-title"
    >
      <header class="regent-next-card__head">
        <h2 id="regent-next-emissions-title">REGENT emissions</h2>
        <span class="regent-next-tag">Paid in REGENT</span>
      </header>
      <p>
        Currently <strong>{@facts.emission_apr_percent}%</strong>
        a year, paid in REGENT while the reward supply lasts. The rate can change.
      </p>
      <dl class="regent-next-rows">
        <div>
          <dt>Reward supply left</dt>
          <dd>
            <TokenDisplay.amount amount={@facts.reward_inventory.amount} unit="REGENT" />
          </dd>
        </div>
      </dl>
      <p class="regent-next-source">
        Read from the staking contract at Base block {block(@facts)}. Emissions are a separate stream
        from the USDC above and are never added to it.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :parts, :list, required: true

  defp split_bar(assigns) do
    ~H"""
    <div class="regent-next-split">
      <div class="regent-next-bar" aria-hidden="true">
        <span
          :for={part <- @parts}
          :if={Decimal.gt?(part.share, 0)}
          class={"regent-next-bar__part regent-next-bar__part--#{part.key}"}
          style={"width: #{width(part.share)}%"}
        ></span>
      </div>
      <ul class="regent-next-legend">
        <li :for={part <- @parts} class={"regent-next-legend__#{part.key}"}>
          {part.label} <strong>{percent(part.share)}</strong>
        </li>
      </ul>
    </div>
    """
  end

  # The stakers' and the treasury's shares of an amount received, when there
  # was anything received to share.
  defp parts(received, stakers, treasury) do
    whole = Decimal.new(received)

    if Decimal.gt?(whole, 0) do
      [
        %{key: :stakers, label: "Stakers", share: Decimal.div(Decimal.new(stakers), whole)},
        %{
          key: :treasury,
          label: "Regent's treasury",
          share: Decimal.div(Decimal.new(treasury), whole)
        }
      ]
    end
  end

  defp source_received(%{deposits_7d: :unavailable}, _source), do: nil

  defp source_received(%{deposits_7d: %{sources: sources}}, source),
    do: sources |> Map.new() |> Map.fetch!(source) |> Map.fetch!(:received)

  defp source_name(:memestake_base), do: "Memestake trades on Base"
  defp source_name(:token_splitters), do: "Regent's 2% of token staking rewards"
  defp source_name(:robinhood), do: "Memestake trades on Robinhood Chain"
  defp source_name({:tag, text}), do: "Tagged “#{text}”"
  defp source_name(:unattributed), do: "Unattributed"

  defp source_note(:memestake_base),
    do: "The stock-side share, swapped to USDC. Recorded as autolaunch-stocks."

  defp source_note(:token_splitters),
    do:
      "The USDC part of Memestake and Revstake staking rewards. Recorded with the token's address."

  defp source_note(:robinhood),
    do: "Arrives once the transfer to Base is set up. Recorded as autolaunch-robinhood."

  defp source_note({:tag, _text}),
    do: "Recorded with this tag. This page does not say which product it came from."

  defp source_note(:unattributed), do: "Recorded without a source this page can read."

  defp deposit_count(1), do: "One deposit"
  defp deposit_count(count), do: "#{grouped(count)} deposits"

  defp block(facts), do: grouped(facts.block_number)

  # A USDC amount to the cent, never rounded up.
  defp usdc(amount), do: "#{dollars(amount)} USDC"

  # A dollar amount, USDC or USDG, to the cent, never rounded up.
  defp dollars(amount),
    do:
      amount
      |> Decimal.new()
      |> Decimal.round(2, :down)
      |> Decimal.to_string(:normal)
      |> Amounts.grouped()

  # A fraction as a percent to two decimal places, so a split's two parts
  # read to the same precision and add up to 100%.
  defp percent(fraction) do
    fraction
    |> Decimal.mult(100)
    |> Decimal.round(2)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> Kernel.<>("%")
  end

  # A bar segment's width, at least a sliver so a small part stays visible.
  defp width(share) do
    share
    |> Decimal.mult(100)
    |> Decimal.max(Decimal.new("0.5"))
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  defp grouped(number), do: Amounts.grouped(Integer.to_string(number))
end
