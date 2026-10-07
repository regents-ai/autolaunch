defmodule AutolaunchWeb.Components.TokenNext do
  @moduledoc """
  The pieces of the token page (`/tokens/<TICKER>/<tail>`), all drawn
  from the pool facts the page already reads (`Autolaunch.Pool` on Base,
  `Autolaunch.Robinhood.Pool` on Robinhood Chain) and, inside the staking
  card, the signed-in wallet's own position:

    * `reward_trace/1` - one trading fee followed from the trade to a
      staker's claim, with the pool fee and Regent's share beside it;
    * `stake_figures/1` - the wallet's rewards, one row per asset, and its
      staked tokens in a card of their own;
    * `stake_impact/1` - the wallet's share now and after the amount typed
      in the staking form, as a worked example;
    * `reward_history/1` - every reward counted for stakers, per asset, as
      a running total whose steps open their transactions;
    * `treasury_vesting/1` - a Revstake treasury's tokens, released, ready
      to release and still locked over the vesting year;
    * `liquidity/1` - the locked positions, each placed on the price range
      with what it holds now.

  Every rule is the launch's own contracts', first or second launchpad alike:
  a Memestake splitter keeps 2% for
  Regent and splits the rest by stake between everyone staked when rewards
  arrive, or gives all of it to Regent while nothing is staked; a Revstake
  splitter keeps 2% for Regent, gives stakers the rest in line with the
  share of the whole supply staked, and sends what is left to the token's
  treasury. Regent's 2% is read from the splitter itself (`SKIM_BPS`). A
  second-launchpad Memestake also pays its creator a lane of every trade and
  vests the creator's tokens; a Revstake trade pays 1% to Regent beside the
  stakers' 2%. Every
  figure says where it comes from: read from the chain at a block, worked out
  from what was read, or unavailable and why. Fees still waiting in the pool
  or its positions are never shown as anyone's reward.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Stocks.{Amounts, FeeSchedule}
  alias AutolaunchWeb.Components.BidPlaced
  alias AutolaunchWeb.TokenDisplay

  @bps 10_000
  # The rewards chart's drawing box and inset.
  @stairs_width 600
  @stairs_height 160
  @stairs_inset 8
  # The range picture: a bound this far out is the end of the price scale,
  # and the window reaches at least this many ticks (about 3x in price)
  # beyond what it shows.
  @scale_end 887_000
  @range_margin 11_000
  # RegentFeeHook's Regent lane on every Revstake trade, beside the stakers' lane.
  @revstake_regent_bps 100

  attr :id, :string, required: true
  attr :pool, :map, required: true, doc: "the token's pool facts"
  attr :supply, :any, required: true, doc: "the token's whole supply in whole tokens, or nil"

  @doc """
  One trading fee followed through each step until a staker can claim it.
  The steps are the same money moving on, not amounts to add up.
  """
  def reward_trace(assigns) do
    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        skim_bps: assigns.pool.fees.splitter.skim_bps,
        net_bps: @bps - assigns.pool.fees.splitter.skim_bps,
        split: split(assigns.pool, positive(assigns.supply))
      )

    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>Follow one reward, from trade to claim</h2>
        <span class="token-next-tag">{kind_label(@pool)}</span>
      </header>
      <p class="token-next-lead">
        Each step is the same money moving on. The steps are not separate amounts to add up.
      </p>
      <.memestake_steps :if={@pool.kind == :stocks} id={@id} pool={@pool} block={@block} />
      <.revstake_steps :if={@pool.kind == :agent} id={@id} pool={@pool} block={@block} />
      <.split_step
        id={@id}
        pool={@pool}
        split={@split}
        skim_bps={@skim_bps}
        net_bps={@net_bps}
        block={@block}
      />
      <div class="token-next-step token-next-step--claim">
        <span class="token-next-step__mark" aria-hidden="true">{claim_step(@pool)}</span>
        <div class="token-next-step__body">
          <h3>Yours to claim</h3>
          <p>
            Your part waits in the staking contract until you claim it.
            <a href="#stake" class="token-next-link">See your rewards</a>
          </p>
        </div>
      </div>
      <.pool_fee_branch id={@id} pool={@pool} block={@block} />
      <.regent_branch id={@id} pool={@pool} block={@block} />
      <.creator_branch
        :if={@pool.kind == :stocks && @pool.version == :v2}
        id={@id}
        pool={@pool}
        block={@block}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  defp memestake_steps(assigns) do
    assigns =
      assign(assigns,
        rate: FeeSchedule.lane(assigns.pool.chain, assigns.pool.version, :stakers).rate,
        charged:
          sum(assigns.pool.fees.stakers.accrued, assigns.pool.fees.stakers.settled_currency)
      )

    ~H"""
    <ol class="token-next-steps">
      <li class="token-next-step">
        <span class="token-next-step__mark" aria-hidden="true">1</span>
        <div class="token-next-step__body">
          <h3>Charged on each trade</h3>
          <p>
            {@rate} of the {@pool.currency.symbol} side of every trade, for {@pool.token.symbol} stakers.
          </p>
          <p class="token-next-figure">
            <TokenDisplay.tokens amount={@charged} unit={@pool.currency.symbol} /> so far
          </p>
          <p class="token-next-source">
            Worked out at block {@block}: what is waiting now plus what has been sent.
          </p>
        </div>
      </li>
      <li class="token-next-step">
        <span class="token-next-step__mark" aria-hidden="true">2</span>
        <div class="token-next-step__body">
          <h3>Waiting in the pool</h3>
          <p>
            The pool's fee contract holds it. It is not anyone's reward yet. Anyone can send it on
            with Settle for stakers.
          </p>
          <p class="token-next-figure">
            <TokenDisplay.tokens amount={@pool.fees.stakers.accrued} unit={@pool.currency.symbol} />
            waiting
          </p>
          <p class="token-next-source">Read from the chain at block {@block}.</p>
        </div>
      </li>
      <li class="token-next-step">
        <span class="token-next-step__mark" aria-hidden="true">3</span>
        <div class="token-next-step__body">
          <h3>Sent to the staking contract</h3>
          <p>It counts as staking rewards the moment it arrives.</p>
          <p class="token-next-figure">
            <TokenDisplay.tokens
              amount={@pool.fees.stakers.settled_currency}
              unit={@pool.currency.symbol}
            /> sent so far
          </p>
          <.latest_tx chain={@pool.chain} entry={settled(@pool, :stakers)} />
          <p class="token-next-source">Read from the chain at block {@block}.</p>
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  defp revstake_steps(assigns) do
    ~H"""
    <ol class="token-next-steps">
      <li class="token-next-step">
        <span class="token-next-step__mark" aria-hidden="true">1</span>
        <div class="token-next-step__body">
          <h3>Charged on each trade</h3>
          <p>
            {bps_percent(@pool.fees.lane_bps)} of every trade, for {@pool.token.symbol} stakers. It is paid in {@pool.currency.symbol} or {@pool.token.symbol}, depending on the side of the trade.
          </p>
          <p class="token-next-figure">
            <TokenDisplay.tokens amount={@pool.fees.per_lane.currency} unit={@pool.currency.symbol} />
            and <TokenDisplay.tokens amount={@pool.fees.per_lane.token} unit={@pool.token.symbol} />
            so far
          </p>
          <p class="token-next-source">
            Added up from every trade since the pool opened, to block {@block}.
          </p>
        </div>
      </li>
      <li class="token-next-step">
        <span class="token-next-step__mark" aria-hidden="true">2</span>
        <div class="token-next-step__body">
          <h3>Sent to the staking contract with the trade</h3>
          <p>
            It reaches the staking contract in the same trade and counts as staking rewards at once.
            Nothing waits in between.
          </p>
          <.latest_tx chain={@pool.chain} entry={arrived(@pool, @pool.hook)} />
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :split, :map, required: true
  attr :skim_bps, :integer, required: true
  attr :net_bps, :integer, required: true
  attr :block, :string, required: true

  # How rewards are split when they arrive, and how the next arrival would be
  # split with the stake as it is now.
  defp split_step(assigns) do
    ~H"""
    <div class="token-next-step">
      <span class="token-next-step__mark" aria-hidden="true">{split_step_number(@pool)}</span>
      <div class="token-next-step__body">
        <h3>Split when it arrives</h3>
        <p :if={@pool.kind == :stocks}>
          Regent keeps {bps_percent(@skim_bps)}. The other {bps_percent(@net_bps)} is split by
          stake between everyone staked at that moment. With nobody staking, all of it goes to Regent.
        </p>
        <p :if={@pool.kind == :agent}>
          Regent keeps {bps_percent(@skim_bps)}. Stakers get the other {bps_percent(@net_bps)} in line with the share of all {@pool.token.symbol} that is staked. The rest goes to the
          token's treasury.
        </p>
        <div :if={@split != :unavailable} class="token-next-split">
          <p class="token-next-split__lead">{@split.lead}</p>
          <div class="token-next-bar" aria-hidden="true">
            <span
              :for={part <- @split.parts}
              :if={Decimal.gt?(part.share, 0)}
              class={"token-next-bar__part token-next-bar__part--#{part.key}"}
              style={"width: #{width(part.share)}%"}
            ></span>
          </div>
          <ul class="token-next-legend">
            <li :for={part <- @split.parts} class={"token-next-legend__#{part.key}"}>
              {part.label} <strong>{split_percent(part.share)}</strong>
            </li>
          </ul>
          <p class="token-next-source">{@split.source}</p>
        </div>
        <p :if={@split == :unavailable} class="token-next-source">
          How the next amount would be split is unavailable: this token's total supply is not
          recorded yet.
        </p>
        <p class="token-next-source">
          Past amounts were split by the stake at the time each one arrived. This page does not read
          each past split.
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  # The pool fee the locked liquidity earns: it waits in each position until
  # anyone collects it, then arrives in the same staking contract.
  defp pool_fee_branch(assigns) do
    assigns = assign(assigns, :rate, pool_rate(assigns.pool))

    ~H"""
    <section class="token-next-branch" aria-labelledby={"#{@id}-pool-fee"}>
      <h3 id={"#{@id}-pool-fee"}>
        <.info_tip
          id={"#{@id}-pool-fee-tip"}
          text="Uniswap charges this on every trade. The pool's liquidity is locked forever, so what it earns can only go to stakers."
        >
          Also for stakers: the {@rate} pool fee
        </.info_tip>
      </h3>
      <p>
        What the locked liquidity earns waits in its positions. Anyone can send it to the staking
        contract with Collect trading fees, and it is split the same way when it arrives.
      </p>
      <dl class="token-next-rows">
        <div :for={position <- @pool.positions}>
          <dt>{position_name(position)} · waiting</dt>
          <dd :if={position.uncollected}>
            <TokenDisplay.tokens amount={position.uncollected.token_amount} unit={@pool.token.symbol} />
            ·
            <TokenDisplay.tokens
              amount={position.uncollected.currency_amount}
              unit={@pool.currency.symbol}
            />
          </dd>
          <dd :if={!position.uncollected}>Unavailable: this could not be read just now.</dd>
        </div>
      </dl>
      <.latest_tx chain={@pool.chain} entry={arrived(@pool, @pool.locker)} label="Latest collection" />
      <p class="token-next-source">
        Read from the chain at block {@block}, as what collecting now would send. Fees already
        collected are not added up here.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  # Regent's own lane: not part of the token stakers' rewards.
  defp regent_branch(%{pool: %{kind: :agent}} = assigns) do
    assigns = assign(assigns, :rate, bps_percent(@revstake_regent_bps))

    ~H"""
    <section class="token-next-branch" aria-labelledby={"#{@id}-regent"}>
      <h3 id={"#{@id}-regent"}>Beside it: {@rate} to Regent</h3>
      <p>
        Another {@rate} of every trade goes to Regent with the trade. It is not part of staking rewards.
      </p>
    </section>
    """
  end

  defp regent_branch(assigns) do
    assigns =
      assign(
        assigns,
        :rate,
        FeeSchedule.lane(assigns.pool.chain, assigns.pool.version, :regent).rate
      )

    ~H"""
    <section class="token-next-branch" aria-labelledby={"#{@id}-regent"}>
      <h3 id={"#{@id}-regent"}>Beside it: {@rate} to REGENT stakers</h3>
      <p :if={@pool.chain == :base}>
        Another {@rate} of the {@pool.currency.symbol} side goes to REGENT stakers. It waits in the
        pool, is swapped to USDC and is paid into REGENT staking on Base. It is not part of {@pool.token.symbol} staking rewards.
      </p>
      <p :if={@pool.chain == :robinhood}>
        Another {@rate} of the {@pool.currency.symbol} side is for REGENT stakers. It waits in the
        pool, is swapped to USDG and is held on Robinhood Chain until the transfer to Base is set up.
        It is not part of {@pool.token.symbol} staking rewards.
      </p>
      <dl class="token-next-rows">
        <div>
          <dt>Waiting in the pool</dt>
          <dd>
            <TokenDisplay.tokens amount={@pool.fees.regent.accrued} unit={@pool.currency.symbol} />
          </dd>
        </div>
        <div>
          <dt>Swapped so far</dt>
          <dd>
            <TokenDisplay.tokens
              amount={@pool.fees.regent.settled_currency}
              unit={@pool.currency.symbol}
            />
          </dd>
        </div>
        <div :if={@pool.chain == :base}>
          <dt>Paid into REGENT staking</dt>
          <dd><TokenDisplay.tokens amount={@pool.fees.regent.settled_usdc} unit="USDC" /></dd>
        </div>
        <div :if={@pool.chain == :robinhood}>
          <dt>Sent on as USDG so far</dt>
          <dd><TokenDisplay.tokens amount={@pool.fees.regent.settled_usdc} unit="USDG" /></dd>
        </div>
      </dl>
      <.latest_tx chain={@pool.chain} entry={settled(@pool, :regent)} label="Latest swap" />
      <p class="token-next-source">Read from the chain at block {@block}.</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  # The creator's own lane and vesting: neither is part of staking rewards.
  defp creator_branch(assigns) do
    assigns =
      assign(assigns, :rate, FeeSchedule.lane(assigns.pool.chain, :v2, :creator).rate)

    ~H"""
    <section class="token-next-branch" aria-labelledby={"#{@id}-creator"}>
      <h3 id={"#{@id}-creator"}>Beside it: {@rate} to the creator</h3>
      <p>
        Another {@rate} of the {@pool.currency.symbol} side goes to the wallet that created the
        launch. It waits in the pool until anyone sends it on. It is not part of {@pool.token.symbol} staking rewards.
      </p>
      <dl class="token-next-rows">
        <div>
          <dt>Waiting in the pool</dt>
          <dd>
            <TokenDisplay.tokens amount={@pool.fees.creator.accrued} unit={@pool.currency.symbol} />
          </dd>
        </div>
        <div>
          <dt>Paid to the creator so far</dt>
          <dd>
            <TokenDisplay.tokens
              amount={@pool.fees.creator.settled_currency}
              unit={@pool.currency.symbol}
            />
          </dd>
        </div>
        <div :if={@pool.vesting}>
          <dt>Creator's {@pool.token.symbol} released so far</dt>
          <dd>
            <TokenDisplay.tokens amount={@pool.vesting.released} unit={@pool.token.symbol} />
          </dd>
        </div>
        <div :if={@pool.vesting}>
          <dt>Ready to release to the creator</dt>
          <dd>
            <TokenDisplay.tokens amount={@pool.vesting.releasable} unit={@pool.token.symbol} />
          </dd>
        </div>
      </dl>
      <.latest_tx chain={@pool.chain} entry={settled(@pool, :creator)} label="Latest payment" />
      <p class="token-next-source">Read from the chain at block {@block}.</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :asset, :atom, default: nil, doc: "the asset chosen: :stock, :dollar or :token"

  @doc """
  Every reward the staking contract has counted for stakers, in one asset at
  a time, as a running total since the pool opened. Each step is one arrival
  and opens its transaction. The figures are everyone's together: a wallet's
  own claimable and claimed amounts are in the staking card.
  """
  def reward_history(assigns) do
    assets = reward_assets(assigns.pool)

    chosen =
      Enum.find(assets, &(&1.key == assigns.asset)) || Enum.find(assets, &(&1.steps != [])) ||
        hd(assets)

    assigns =
      assign(assigns,
        assets: assets,
        chosen: chosen,
        chart: staircase(chosen, assigns.pool),
        block: grouped(assigns.pool.block.number)
      )

    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>
          <.info_tip
            id={"#{@id}-tip"}
            text="Everything the staking contract has counted for all stakers together. Each step is one arrival; select it to open the transaction."
          >
            Stakers' rewards over time
          </.info_tip>
        </h2>
        <div class="token-next-choice" role="group" aria-label="Reward asset">
          <button
            :for={asset <- @assets}
            type="button"
            class="token-next-choice__option"
            aria-pressed={to_string(asset.key == @chosen.key)}
            phx-click="reward_asset"
            phx-value-asset={asset.key}
          >
            {asset.symbol}
          </button>
        </div>
      </header>
      <div class="token-next-stairs">
        <svg
          :if={@chart.steps != []}
          viewBox={"0 0 #{@chart.width} #{@chart.height}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={"Running total of #{@chosen.symbol} rewards"}
        >
          <path class="token-next-stairs__line" d={@chart.path} />
          <a
            :for={step <- @chart.steps}
            href={BidPlaced.transaction_url(@pool.chain, step.transaction_hash)}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={"Block #{grouped(step.block)}: #{step.added} #{@chosen.symbol}"}
          >
            <circle class="token-next-stairs__step" cx={step.x} cy={step.y} r="5">
              <title>Block {grouped(step.block)}: +{step.added} {@chosen.symbol}</title>
            </circle>
          </a>
        </svg>
        <p :if={@chart.steps == []} class="token-next-stairs__empty token-next-muted">
          No {@chosen.symbol} rewards counted yet.
        </p>
      </div>
      <dl class="token-next-rows">
        <div>
          <dt>Counted for stakers so far</dt>
          <dd><TokenDisplay.tokens amount={@chart.total} unit={@chosen.symbol} /></dd>
        </div>
        <div>
          <dt>Arrivals</dt>
          <dd>{grouped(length(@chart.steps))}</dd>
        </div>
      </dl>
      <p class="token-next-source">
        Read from the staking contract's own records, from the pool's opening to block {@block}.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true

  @doc """
  A Revstake treasury's tokens in the launch's vesting escrow: what has gone
  to the treasury, what anyone can release to it now, and what is still
  locked, on the year it vests over.
  """
  def treasury_vesting(assigns) do
    vesting = assigns.pool.treasury_vesting

    assigns =
      assign(assigns,
        vesting: vesting,
        parts: vesting_parts(vesting),
        today: vesting_elapsed(vesting),
        block: grouped(assigns.pool.block.number)
      )

    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>
          <.info_tip
            id={"#{@id}-tip"}
            text="The treasury's tokens are held by the launch's vesting escrow and unlock in a straight line over 365 days from graduation. Anyone can send the unlocked part to the treasury."
          >
            The treasury's tokens
          </.info_tip>
        </h2>
        <span class="token-next-tag">Vests over a year</span>
      </header>
      <div :if={@vesting.state == :graduated} class="token-next-vesting">
        <div class="token-next-vesting__track">
          <div class="token-next-bar" aria-hidden="true">
            <span
              :for={part <- @parts}
              :if={Decimal.gt?(part.share, 0)}
              class={"token-next-bar__part token-next-bar__part--#{part.key}"}
              style={"width: #{width(part.share)}%"}
            ></span>
          </div>
          <span class="token-next-vesting__today" style={"left: #{width(@today)}%"}>Today</span>
        </div>
        <div class="token-next-vesting__dates">
          <span>{date(@vesting.starts_at)}</span>
          <span>{date(@vesting.ends_at)}</span>
        </div>
        <ul class="token-next-legend">
          <li :for={part <- @parts} class={"token-next-legend__#{part.key}"}>
            {part.label} <strong>{split_percent(part.share)}</strong>
          </li>
        </ul>
      </div>
      <p :if={@vesting.state == :pending} class="token-next-lead">
        Vesting starts when the auction graduates.
      </p>
      <p :if={@vesting.state == :failed} class="token-next-lead">
        This launch did not graduate, so nothing vests to the treasury.
      </p>
      <dl class="token-next-rows">
        <div>
          <dt>Sent to the treasury</dt>
          <dd>
            <TokenDisplay.tokens
              amount={units(@vesting.released, @vesting)}
              unit={@pool.token.symbol}
            />
          </dd>
        </div>
        <div>
          <dt>Ready to send</dt>
          <dd>
            <TokenDisplay.tokens
              amount={units(@vesting.releasable, @vesting)}
              unit={@pool.token.symbol}
            />
          </dd>
        </div>
        <div>
          <dt>Still locked</dt>
          <dd>
            <TokenDisplay.tokens amount={units(@vesting.locked, @vesting)} unit={@pool.token.symbol} />
          </dd>
        </div>
        <div>
          <dt>Held by</dt>
          <dd>
            <a
              href={BidPlaced.address_url(@pool.chain, @vesting.address)}
              target="_blank"
              rel="noopener noreferrer"
              class="token-next-link autolaunch-exact-value"
            >
              {@vesting.address} ↗
            </a>
          </dd>
        </div>
      </dl>
      <p class="token-next-source">
        Read from the escrow at block {@block}; the unlocked part is worked out the way the escrow
        works it out.
      </p>
    </section>
    """
  end

  attr :chain, :atom, required: true

  attr :entry, :any,
    required: true,
    doc: "the latest record with its block and transaction, or nil"

  attr :label, :string, default: "Latest"

  # The most recent time this money moved, opening its transaction.
  defp latest_tx(assigns) do
    ~H"""
    <p class="token-next-tx">
      <span class="token-next-muted">{@label}:</span>
      <a
        :if={@entry}
        href={BidPlaced.transaction_url(@chain, @entry.transaction_hash)}
        target="_blank"
        rel="noopener noreferrer"
        class="token-next-link"
      >
        block {grouped(@entry.block)} ↗
      </a>
      <span :if={!@entry} class="token-next-muted">none yet</span>
    </p>
    """
  end

  # The latest lane settlement the pool's hook emitted for `lane`.
  defp settled(pool, lane),
    do: pool.fees.settlements |> Enum.filter(&(&1.lane == lane)) |> List.last()

  # The latest reward the staking contract counted from `source`.
  defp arrived(pool, source),
    do: pool.rewards |> Enum.filter(&(&1.source == String.downcase(source))) |> List.last()

  attr :id, :string, required: true
  attr :pool, :map, required: true

  attr :position, :any,
    default: nil,
    doc:
      "the signed-in wallet's position, nil when signed out, or :unread when it could not be read"

  @doc """
  The wallet's rewards, one row per asset, and its staked tokens in a card of
  their own. Only rewards already counted by the staking contract are shown
  as the wallet's; fees still waiting are not.
  """
  def stake_figures(assigns) do
    mine = if is_map(assigns.position), do: assigns.position

    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        rows: reward_rows(assigns.pool, mine),
        mine: mine,
        missing:
          if(assigns.position == :unread,
            do: "Can't be read right now",
            else: "Sign in to see yours"
          )
      )

    ~H"""
    <div id={@id} class="token-next-stake">
      <section class="token-next-basket" aria-labelledby={"#{@id}-rewards"}>
        <h3 id={"#{@id}-rewards"}>Your rewards</h3>
        <ul class="token-next-basket__rows">
          <li :for={row <- @rows}>
            <span class="token-next-basket__asset">
              <span class="ticker">{row.symbol}</span>
              <small>{row.note}</small>
            </span>
            <span :if={row.amount} class="token-next-basket__amount">
              <TokenDisplay.tokens amount={row.amount} unit={row.symbol} />
              <small>
                Claimed so far <TokenDisplay.tokens amount={row.claimed} unit={row.symbol} />
              </small>
            </span>
            <span :if={!row.amount} class="token-next-basket__amount token-next-muted">
              {@missing}
            </span>
          </li>
        </ul>
        <p class="token-next-source">
          {if @mine,
            do: "Read from the chain at block #{@block}.",
            else: "Each asset is its own reward."} Only rewards the staking contract has counted can be
          claimed. Fees still waiting in the pool are not yours yet.
        </p>
        <p class="token-next-source">
          Claim rewards sends all three to your wallet. It does not swap or stake them.
        </p>
      </section>
      <section class="token-next-principal" aria-labelledby={"#{@id}-principal"}>
        <h3 id={"#{@id}-principal"}>Your staked {@pool.token.symbol}</h3>
        <dl class="token-next-rows">
          <div>
            <dt>Your stake</dt>
            <dd :if={@mine}>
              <TokenDisplay.tokens amount={@mine.staked.shown} unit={@pool.token.symbol} />
            </dd>
            <dd :if={!@mine} class="token-next-muted">{@missing}</dd>
          </div>
          <div :if={@mine}>
            <dt>In your wallet</dt>
            <dd>
              <TokenDisplay.tokens amount={@mine.balance.shown} unit={@pool.token.symbol} />
            </dd>
          </div>
          <div>
            <dt>Staked by everyone</dt>
            <dd>
              <TokenDisplay.tokens
                amount={@pool.fees.splitter.total_staked}
                unit={@pool.token.symbol}
              />
            </dd>
          </div>
        </dl>
        <p class="token-next-source">Read from the chain at block {@block}.</p>
        <p class="token-next-source">
          Unstaking gives your {@pool.token.symbol} back; it is separate from claiming rewards.
          Claiming and unstaking open from the block after your latest stake, and staking more
          starts that wait again for your whole stake.
        </p>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :amount, :string, required: true, doc: "the amount typed in the staking form"

  attr :position, :any,
    default: nil,
    doc:
      "the signed-in wallet's position, nil when signed out, or :unread when it could not be read"

  attr :supply, :any, default: nil, doc: "the token's whole supply in whole tokens, or nil"

  @doc """
  What staking the typed amount would change: the wallet's share now and
  after, and what that share would be of each 1 of rewards counted later.
  A Memestake share is of everything staked; a Revstake share is of the
  whole supply. It is an example on today's figures, not a forecast.
  """
  def stake_impact(assigns) do
    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        impact: impact(assigns.pool, assigns.position, assigns.amount, positive(assigns.supply))
      )

    ~H"""
    <section id={@id} class="token-next-impact" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h3 id={"#{@id}-title"}>What changes if you stake</h3>
        <span class="token-next-tag">Example, not a forecast</span>
      </header>
      <p :if={@impact == :waiting} class="token-next-source">
        Enter an amount above to see your share before and after staking it.
      </p>
      <p :if={@impact == :unread} class="token-next-source">
        Unavailable: your stake could not be read just now, so your share cannot be worked out.
      </p>
      <p :if={@impact == :no_supply} class="token-next-source">
        Unavailable: this token's total supply is not recorded yet, so its share cannot be worked out.
      </p>
      <div :if={is_map(@impact)} class="token-next-impact__body">
        <dl class="token-next-impact__figures">
          <div>
            <dt>{@impact.now_label}</dt>
            <dd>{@impact.now}</dd>
          </div>
          <div>
            <dt>{@impact.after_label}</dt>
            <dd>{percent(@impact.after)}</dd>
          </div>
          <div>
            <dt>Of each 1 {@pool.currency.symbol} of rewards counted later</dt>
            <dd>
              <TokenDisplay.price
                amount={Decimal.to_string(@impact.per_unit, :normal)}
                unit={@pool.currency.symbol}
                round={:down}
              />
            </dd>
          </div>
        </dl>
        <p class="token-next-source">
          Staking {@impact.added} {@pool.token.symbol}. The same share applies to {@pool.fees.splitter.dollar.symbol} and {@pool.token.symbol} rewards. The last figure is
          after Regent's {bps_percent(@pool.fees.splitter.skim_bps)}.
        </p>
        <p :if={@pool.kind == :stocks} class="token-next-source">
          Worked out from the stake read at block {@block} and the amount typed: your stake
          plus this amount, over everything staked plus this amount. It assumes nobody else stakes or
          unstakes. Fees waiting now are not included, and it is not a promise of any reward.
        </p>
        <p :if={@pool.kind == :agent} class="token-next-source">
          Worked out from your stake read at block {@block} and the amount typed: your stake
          plus this amount, over all {@impact.supply} {@pool.token.symbol}. Your share does not depend
          on what others stake: the part for unstaked {@pool.token.symbol} goes to the token's
          treasury. It is not a promise of any reward.
        </p>
        <p :if={!@position} class="token-next-source">
          Signed out, this is for a wallet with nothing staked yet.
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true

  @doc """
  The locked positions: each placed on the price range beside the price now,
  what it was given at opening and what it holds now, whether the price is
  inside its range so it earns fees, whether the launch's locker holds it,
  and the share of the currency each took at opening.
  """
  def liquidity(assigns) do
    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        shares: currency_shares(assigns.pool.positions),
        picture: range_picture(assigns.pool)
      )

    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>The locked liquidity</h2>
        <span class="token-next-tag">Locked forever</span>
      </header>
      <p class="token-next-lead">{positions_lead(@pool.positions)}</p>
      <figure :if={@picture} class="token-next-range">
        <svg
          viewBox={"0 0 #{@picture.width} #{@picture.height}"}
          role="img"
          aria-label={"Each position's price range beside the price now, in #{@pool.currency.symbol} per #{@pool.token.symbol}"}
        >
          <g :for={row <- @picture.rows}>
            <rect
              class={"token-next-range__bar token-next-range__bar--#{row.key}"}
              x={row.x}
              y={row.y}
              width={row.width}
              height="12"
              rx={if row.open?, do: "0", else: "3"}
            >
              <title>{row.label}</title>
            </rect>
          </g>
          <line
            class="token-next-range__now"
            x1={@picture.now}
            x2={@picture.now}
            y1="0"
            y2={@picture.height}
          />
        </svg>
        <figcaption class="token-next-range__axis">
          <span>{@picture.low}</span>
          <span class="token-next-range__axis-now">
            Now
            <TokenDisplay.price amount={plain(@pool.current.price)} unit={@pool.currency.symbol} />
          </span>
          <span>{@picture.high}</span>
        </figcaption>
        <ul class="token-next-legend">
          <li :for={row <- @picture.rows} class={"token-next-legend__#{row.key}"}>{row.label}</li>
        </ul>
      </figure>
      <ol class="token-next-positions">
        <li :for={position <- @pool.positions} class="token-next-position">
          <header class="token-next-position__head">
            <h3>{position_name(position)}</h3>
            <span class="token-next-muted">Position #{position.token_id}</span>
          </header>
          <p>{position_job(position, @pool)}</p>
          <dl class="token-next-rows">
            <div>
              <dt>Placed at opening</dt>
              <dd>
                <TokenDisplay.tokens amount={position.token_amount} unit={@pool.token.symbol} /> ·
                <TokenDisplay.tokens amount={position.currency_amount} unit={@pool.currency.symbol} />
              </dd>
            </div>
            <div>
              <dt>
                <.info_tip
                  id={"#{@id}-holds-#{position.token_id}"}
                  text="Worked out from the position's range and liquidity at the price now, the way Uniswap works out a withdrawal."
                >
                  Holds now
                </.info_tip>
              </dt>
              <dd :if={position.holds}>
                <TokenDisplay.tokens amount={position.holds.token_amount} unit={@pool.token.symbol} />
                ·
                <TokenDisplay.tokens
                  amount={position.holds.currency_amount}
                  unit={@pool.currency.symbol}
                />
              </dd>
              <dd :if={!position.holds} class="token-next-muted">
                Unavailable: the pool's price could not be read just now.
              </dd>
            </div>
            <div>
              <dt>Earning fees now</dt>
              <dd :if={position.holds && position.holds.in_range?}>
                Yes, the price is inside its range
              </dd>
              <dd :if={position.holds && !position.holds.in_range?}>
                No, the price is outside its range
              </dd>
              <dd :if={!position.holds} class="token-next-muted">Unavailable</dd>
            </div>
            <div>
              <dt>Locked</dt>
              <dd :if={position.locked?}>
                Yes, forever. The launch's locker owns it and can never take it out.
              </dd>
              <dd :if={!position.locked?}>
                Not held by the launch's locker.
                <span class="autolaunch-exact-value">{position.owner}</span>
              </dd>
            </div>
            <div>
              <dt>Its trading fees</dt>
              <dd>Go to {@pool.token.symbol} stakers when collected.</dd>
            </div>
          </dl>
        </li>
      </ol>
      <div :if={@shares} class="token-next-split">
        <p class="token-next-split__lead">
          Where the {@pool.currency.symbol} went at opening
        </p>
        <div class="token-next-bar" aria-hidden="true">
          <span
            :for={share <- @shares}
            :if={Decimal.gt?(share.share, 0)}
            class={"token-next-bar__part token-next-bar__part--#{share.key}"}
            style={"width: #{width(share.share)}%"}
          ></span>
        </div>
        <ul class="token-next-legend">
          <li :for={share <- @shares} class={"token-next-legend__#{share.key}"}>
            {share.label} <strong>{split_percent(share.share)}</strong>
          </li>
        </ul>
      </div>
      <dl :if={@pool.chain == :base} class="token-next-rows">
        <div>
          <dt>Price when the pool opened</dt>
          <dd>
            <TokenDisplay.price amount={plain(@pool.graduation_price)} unit={@pool.currency.symbol} />
            per {@pool.token.symbol}
          </dd>
        </div>
        <div>
          <dt>Price now</dt>
          <dd :if={@pool.current}>
            <TokenDisplay.price amount={plain(@pool.current.price)} unit={@pool.currency.symbol} />
            per {@pool.token.symbol}
          </dd>
          <dd :if={!@pool.current} class="token-next-muted">
            Unavailable: the pool's price could not be worked out just now.
          </dd>
        </div>
      </dl>
      <p class="token-next-source">
        Read from the chain at block {@block}. Locking stops anyone taking the liquidity out. It does
        not fix what the positions hold, and it is not a price floor or a promise to buy back.
      </p>
    </section>
    """
  end

  # The split of the next arriving amount with the stake as it is now.
  defp split(%{kind: :stocks} = pool, _supply) do
    skim = pool.fees.splitter.skim_bps
    block = grouped(pool.block.number)

    if pool.fees.splitter.total_staked_atomic > 0 do
      %{
        lead: "Right now #{staked_words(pool)} is staked, so the next amount splits like this:",
        parts: [
          %{key: :regent, label: "Regent", share: fraction(skim, @bps)},
          %{key: :stakers, label: "Stakers", share: fraction(@bps - skim, @bps)}
        ],
        source: "Worked out from the stake read at block #{block}."
      }
    else
      %{
        lead: "Right now nobody is staking, so the next amount would all go to Regent:",
        parts: [%{key: :regent, label: "Regent", share: Decimal.new(1)}],
        source: "Worked out from the stake read at block #{block}."
      }
    end
  end

  defp split(%{kind: :agent}, nil), do: :unavailable

  defp split(%{kind: :agent} = pool, supply) do
    skim = pool.fees.splitter.skim_bps
    staked = Decimal.div(pool.fees.splitter.total_staked_atomic, whole_atomic(supply, pool))
    net = fraction(@bps - skim, @bps)
    stakers = Decimal.mult(net, staked)

    %{
      lead:
        "Right now #{percent(staked)} of all #{pool.token.symbol} is staked, so the next amount splits like this:",
      parts: [
        %{key: :regent, label: "Regent", share: fraction(skim, @bps)},
        %{key: :stakers, label: "Stakers", share: stakers},
        %{key: :treasury, label: "Token's treasury", share: Decimal.sub(net, stakers)}
      ],
      source:
        "Worked out from the stake read at block #{grouped(pool.block.number)} and the #{grouped_whole(supply)} total supply."
    }
  end

  defp reward_rows(pool, position) do
    claimable = position && position.claimable
    claimed = position && position.claimed

    [
      %{
        symbol: pool.currency.symbol,
        note: currency_note(pool),
        amount: claimable && claimable.stock.shown,
        claimed: claimed && claimed.stock.shown
      },
      %{
        symbol: pool.fees.splitter.dollar.symbol,
        note: "Dollar rewards",
        amount: claimable && claimable.dollar.shown,
        claimed: claimed && claimed.dollar.shown
      },
      %{
        symbol: pool.token.symbol,
        note: "Reward tokens, separate from your stake",
        amount: claimable && claimable.token.shown,
        claimed: claimed && claimed.token.shown
      }
    ]
  end

  # The three reward assets in the staking card's order, each with its
  # counted arrivals and the running total after each one.
  defp reward_assets(pool) do
    for {key, asset} <- [
          stock: pool.currency,
          dollar: pool.fees.splitter.dollar,
          token: pool.token
        ] do
      address = String.downcase(asset.address)

      {steps, _total} =
        pool.rewards
        |> Enum.filter(&(&1.asset == address and &1.amount > 0))
        |> Enum.map_reduce(0, fn reward, total ->
          {Map.put(reward, :total, total + reward.amount), total + reward.amount}
        end)

      %{key: key, symbol: asset.symbol, decimals: asset.decimals, steps: steps}
    end
  end

  # The running total as steps from the first arrival to the block read.
  defp staircase(%{steps: []}, _pool),
    do: %{steps: [], total: "0", width: @stairs_width, height: @stairs_height, path: ""}

  defp staircase(%{steps: [first | _rest] = steps} = asset, pool) do
    span = max(pool.block.number - first.block, 1)
    top = List.last(steps).total
    x = &(@stairs_inset + (&1 - first.block) / span * (@stairs_width - 2 * @stairs_inset))
    y = &(@stairs_height - @stairs_inset - &1 / top * (@stairs_height - 2 * @stairs_inset))

    marks =
      for step <- steps do
        %{
          x: Float.round(x.(step.block), 2),
          y: Float.round(y.(step.total), 2),
          block: step.block,
          transaction_hash: step.transaction_hash,
          added: Amounts.compact_decimal(Rpc.format_units(step.amount, asset.decimals), 6)
        }
      end

    path =
      Enum.map_join(marks, " ", &"H #{&1.x} V #{&1.y}") <> " H #{@stairs_width - @stairs_inset}"

    %{
      steps: marks,
      total: Rpc.format_units(top, asset.decimals),
      width: @stairs_width,
      height: @stairs_height,
      path: "M #{@stairs_inset} #{@stairs_height - @stairs_inset} " <> path
    }
  end

  defp vesting_parts(vesting) do
    for {key, label, amount} <- [
          {:released, "Sent", vesting.released},
          {:ready, "Ready to send", vesting.releasable},
          {:locked, "Locked", vesting.locked}
        ] do
      share =
        if vesting.total > 0,
          do: fraction(Decimal.new(amount), Decimal.new(vesting.total)),
          else: Decimal.new(0)

      %{key: key, label: label, share: share}
    end
  end

  # How far through the vesting year the block read is.
  defp vesting_elapsed(vesting) do
    duration = vesting.ends_at - vesting.starts_at
    elapsed = vesting.now |> Kernel.-(vesting.starts_at) |> max(0) |> min(duration)
    fraction(Decimal.new(elapsed), Decimal.new(duration))
  end

  defp units(amount, %{decimals: decimals}), do: Rpc.format_units(amount, decimals)

  defp date(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%-d %b %Y")

  defp currency_note(%{kind: :stocks}), do: "Stock rewards"
  defp currency_note(%{kind: :agent}), do: "REGENT rewards"

  # The typed amount's effect on the wallet's share. Nothing is worked out
  # until the amount is a positive number.
  defp impact(pool, position, amount, supply) do
    case added(amount, pool.token.decimals) do
      nil -> :waiting
      added -> impact(pool, position, added, amount, supply)
    end
  end

  defp impact(_pool, :unread, _added, _amount, _supply), do: :unread
  defp impact(%{kind: :agent}, _position, _added, _amount, nil), do: :no_supply

  defp impact(pool, position, added, amount, supply) do
    mine = if position, do: position.staked.atomic, else: 0
    net = fraction(@bps - pool.fees.splitter.skim_bps, @bps)
    {now, after_share, labels} = shares(pool, mine, added, supply)

    Map.merge(labels, %{
      now: now,
      after: after_share,
      per_unit: Decimal.mult(net, after_share),
      added: Amounts.grouped(amount),
      supply: supply && grouped_whole(supply)
    })
  end

  defp shares(%{kind: :stocks} = pool, mine, added, _supply) do
    total = pool.fees.splitter.total_staked_atomic

    now =
      cond do
        total == 0 -> "Nobody is staking yet"
        mine == 0 -> "None"
        true -> percent(Decimal.div(mine, total))
      end

    {now, Decimal.div(mine + added, total + added),
     %{now_label: "Your share of the stake now", after_label: "Your share after staking"}}
  end

  defp shares(%{kind: :agent} = pool, mine, added, supply) do
    whole = whole_atomic(supply, pool)
    now = if mine == 0, do: "None", else: percent(Decimal.div(mine, whole))

    {now, Decimal.div(mine + added, whole),
     %{
       now_label: "Your share of all #{pool.token.symbol} now",
       after_label: "Your share after staking"
     }}
  end

  # The typed amount in the token's smallest units, read the way the staking
  # form reads it, or nil until it is a positive amount.
  defp added(amount, decimals) do
    case Amounts.parse_units(amount, decimals) do
      {:ok, atomic} when atomic > 0 -> atomic
      _not_positive -> nil
    end
  end

  # The share of the currency each position took at opening, when there are
  # positions to compare and they took some.
  defp currency_shares([_one]), do: nil

  defp currency_shares(positions) do
    amounts = Enum.map(positions, &{&1, Decimal.new(&1.currency_amount)})

    total =
      Enum.reduce(amounts, Decimal.new(0), fn {_position, amount}, sum ->
        Decimal.add(sum, amount)
      end)

    if Decimal.gt?(total, 0) do
      for {position, amount} <- amounts do
        %{key: position.key, label: position_name(position), share: Decimal.div(amount, total)}
      end
    end
  end

  # Each position's range on a log price scale, rising to the right, with
  # the price now. Ticks are already a log of the price; a token that is the
  # pool's second currency reads them the other way round.
  defp range_picture(%{current: nil}), do: nil

  defp range_picture(pool) do
    side = if pool.token_is_currency0?, do: 1, else: -1
    now = side * pool.current.tick

    bounds =
      for position <- pool.positions do
        {low, high} = Enum.min_max([side * position.range.lower, side * position.range.upper])
        %{key: position.key, label: position_name(position), low: low, high: high}
      end

    shown = bounds |> Enum.flat_map(&[&1.low, &1.high]) |> Enum.filter(&(abs(&1) < @scale_end))
    {low, high} = Enum.min_max([now | shown])
    margin = max(div(high - low, 4), @range_margin)
    {low, high} = {low - margin, high + margin}
    width = 600
    x = &Float.round((min(max(&1, low), high) - low) / (high - low) * width, 2)

    rows =
      bounds
      |> Enum.with_index()
      |> Enum.map(fn {bound, index} ->
        %{
          key: bound.key,
          label: bound.label,
          x: x.(bound.low),
          y: 8 + index * 22,
          width: max(x.(bound.high) - x.(bound.low), 2),
          open?: bound.low < low or bound.high > high
        }
      end)

    %{
      rows: rows,
      width: width,
      height: 8 + length(rows) * 22,
      now: x.(now),
      low: about_price(low, pool),
      high: about_price(high, pool)
    }
  end

  # The price at a scale position, for the picture's ends.
  defp about_price(position, pool) do
    value =
      :math.pow(1.0001, position) *
        :math.pow(10, pool.token.decimals - pool.currency.decimals)

    "about " <>
      Amounts.compact_decimal(Decimal.to_string(Decimal.from_float(value), :normal), 3)
  end

  defp positions_lead([_one]), do: "One pool, one locked position."

  defp positions_lead(positions),
    do:
      "One pool, #{length(positions)} locked positions. Each does a different job across the price range."

  defp position_name(position), do: position.label

  defp position_job(%{key: :full_range}, pool),
    do:
      "Holds #{pool.token.symbol} and #{pool.currency.symbol} across every price, so it supports trading in both directions at any price."

  defp position_job(%{key: :new_only}, pool),
    do:
      "Placed with only #{pool.token.symbol} above the opening price, from the reserve the full-range position did not use. It sells #{pool.token.symbol} only as the price rises into it."

  defp position_job(%{key: :stock_only}, pool),
    do:
      "Placed with only #{pool.currency.symbol}, for the #{pool.currency.symbol} the full-range position could not pair. Whether it is in use at today's price is not shown here."

  defp pool_rate(%{kind: :agent, lp_fee: rate}), do: rate
  defp pool_rate(pool), do: FeeSchedule.lane(pool.chain, pool.version, :pool).rate

  defp kind_label(%{kind: :agent}), do: "Revstake"
  defp kind_label(_pool), do: "Memestake"

  defp split_step_number(%{kind: :agent}), do: 3
  defp split_step_number(_pool), do: 4

  defp claim_step(%{kind: :agent}), do: 4
  defp claim_step(_pool), do: 5

  defp staked_words(pool),
    do:
      "#{pool.fees.splitter.total_staked |> TokenDisplay.short(:down) |> Amounts.grouped()} #{pool.token.symbol}"

  # A supply the page can divide by: a recorded, positive number of tokens.
  defp positive(%Decimal{} = supply), do: if(Decimal.gt?(supply, 0), do: supply)
  defp positive(_supply), do: nil

  defp whole_atomic(supply, pool),
    do: supply |> Decimal.mult(Integer.pow(10, pool.token.decimals)) |> Decimal.to_integer()

  defp grouped_whole(supply),
    do: supply |> Decimal.round(0, :down) |> Decimal.to_string(:normal) |> Amounts.grouped()

  defp sum(left, right),
    do: left |> Decimal.new() |> Decimal.add(Decimal.new(right)) |> Decimal.to_string(:normal)

  defp fraction(part, whole), do: Decimal.div(part, whole)

  # A fraction as a percent to four significant digits, never rounded up.
  defp percent(fraction) do
    fraction
    |> Decimal.mult(100)
    |> Decimal.to_string(:normal)
    |> TokenDisplay.short(:down)
    |> TokenDisplay.zeros()
    |> Kernel.<>("%")
  end

  defp bps_percent(bps), do: percent(fraction(bps, @bps))

  # A bar part's percent to two decimal places, so a split's parts read to the
  # same precision and add up to 100%.
  defp split_percent(fraction) do
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

  defp plain(%{value: value}), do: String.trim_trailing(value, "…")

  defp grouped(number), do: Amounts.grouped(Integer.to_string(number))
end
