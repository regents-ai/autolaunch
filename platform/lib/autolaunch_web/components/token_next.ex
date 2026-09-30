defmodule AutolaunchWeb.Components.TokenNext do
  @moduledoc """
  The pieces of the new token page (`/next/tokens/<TICKER>/<tail>`), all drawn
  from the pool facts the page already reads (`Autolaunch.Pool` on Base,
  `Autolaunch.Robinhood.Pool` on Robinhood Chain) and, inside the staking
  card, the signed-in wallet's own position:

    * `reward_trace/1` - one trading fee followed from the trade to a
      staker's claim, with the pool fee and Regent's share beside it;
    * `stake_figures/1` - the wallet's rewards, one row per asset, and its
      staked tokens in a card of their own;
    * `stake_impact/1` - the wallet's share now and after the amount typed
      in the staking form, as a worked example;
    * `liquidity/1` - the locked positions the pool opened with.

  Every rule is the live v1 contracts': a Memestake splitter keeps 2% for
  Regent and splits the rest by stake between everyone staked when rewards
  arrive, or gives all of it to Regent while nothing is staked; a Revstake
  splitter keeps 2% for Regent, gives stakers the rest in line with the
  share of the whole supply staked, and sends what is left to the token's
  treasury. Regent's 2% is read from the splitter itself (`SKIM_BPS`). Every
  figure says where it comes from: read from the chain at a block, worked out
  from what was read, or unavailable and why. Fees still waiting in the pool
  or its positions are never shown as anyone's reward.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.Stocks.{Amounts, FeeSchedule}
  alias AutolaunchWeb.TokenDisplay

  @bps 10_000

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
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :block, :string, required: true

  defp memestake_steps(assigns) do
    assigns =
      assign(assigns,
        rate: FeeSchedule.lane(assigns.pool.chain, :stakers).rate,
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
              {part.label} <strong>{percent(part.share)}</strong>
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
    ~H"""
    <section class="token-next-branch" aria-labelledby={"#{@id}-regent"}>
      <h3 id={"#{@id}-regent"}>Beside it: {bps_percent(@pool.fees.lane_bps)} to Regent</h3>
      <p>
        Another {bps_percent(@pool.fees.lane_bps)} of every trade goes to Regent with the trade. It is not part of staking rewards.
      </p>
      <dl class="token-next-rows">
        <div>
          <dt>Sent to Regent so far</dt>
          <dd>
            <TokenDisplay.tokens amount={@pool.fees.per_lane.currency} unit={@pool.currency.symbol} />
            · <TokenDisplay.tokens amount={@pool.fees.per_lane.token} unit={@pool.token.symbol} />
          </dd>
        </div>
      </dl>
      <p class="token-next-source">
        Added up from every trade since the pool opened, to block {@block}.
      </p>
    </section>
    """
  end

  defp regent_branch(assigns) do
    assigns = assign(assigns, :rate, FeeSchedule.lane(assigns.pool.chain, :regent).rate)

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
          <dd><TokenDisplay.tokens amount={@pool.fees.regent.settled_usdg} unit="USDG" /></dd>
        </div>
      </dl>
      <p class="token-next-source">Read from the chain at block {@block}.</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :pool, :map, required: true
  attr :position, :map, default: nil, doc: "the signed-in wallet's position, or nil"

  @doc """
  The wallet's rewards, one row per asset, and its staked tokens in a card of
  their own. Only rewards already counted by the staking contract are shown
  as the wallet's; fees still waiting are not.
  """
  def stake_figures(assigns) do
    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        rows: reward_rows(assigns.pool, assigns.position)
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
            </span>
            <span :if={!row.amount} class="token-next-basket__amount token-next-muted">
              Sign in to see yours
            </span>
          </li>
        </ul>
        <p class="token-next-source">
          {if @position,
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
            <dd :if={@position}>
              <TokenDisplay.tokens amount={@position.staked.shown} unit={@pool.token.symbol} />
            </dd>
            <dd :if={!@position} class="token-next-muted">Sign in to see yours</dd>
          </div>
          <div :if={@position}>
            <dt>In your wallet</dt>
            <dd>
              <TokenDisplay.tokens amount={@position.balance.shown} unit={@pool.token.symbol} />
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
  attr :position, :map, default: nil, doc: "the signed-in wallet's position, or nil"
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
  The locked positions the pool opened with: what each was given, whether
  the launch's locker holds it, the share of the currency each took and what
  its trading fees are waiting to send. What a position holds now changes
  with every trade and is not read here.
  """
  def liquidity(assigns) do
    assigns =
      assign(assigns,
        block: grouped(assigns.pool.block.number),
        shares: currency_shares(assigns.pool.positions)
      )

    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>The locked liquidity</h2>
        <span class="token-next-tag">As placed at opening</span>
      </header>
      <p class="token-next-lead">{positions_lead(@pool.positions)}</p>
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
              <dt>Held now</dt>
              <dd class="token-next-muted">
                Unavailable: trades change it, and this page reads only what was placed.
              </dd>
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
            {share.label} <strong>{percent(share.share)}</strong>
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

    [
      %{
        symbol: pool.currency.symbol,
        note: currency_note(pool),
        amount: claimable && claimable.stock.shown
      },
      %{
        symbol: pool.fees.splitter.dollar.symbol,
        note: "Dollar rewards",
        amount: claimable && claimable.dollar.shown
      },
      %{
        symbol: pool.token.symbol,
        note: "Reward tokens, separate from your stake",
        amount: claimable && claimable.token.shown
      }
    ]
  end

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

  defp positions_lead([_one]), do: "One pool, one locked position."

  defp positions_lead(positions),
    do:
      "One pool, #{length(positions)} locked positions. Each does a different job across the price range."

  defp position_name(%{key: :full_range}), do: "Full range"
  defp position_name(%{key: :stock_only}), do: "One-sided"

  defp position_job(%{key: :full_range}, pool),
    do:
      "Holds #{pool.token.symbol} and #{pool.currency.symbol} across every price, so it supports trading in both directions at any price."

  defp position_job(%{key: :stock_only}, pool),
    do:
      "Placed with only #{pool.currency.symbol}, for the #{pool.currency.symbol} the full-range position could not pair. Whether it is in use at today's price is not shown here."

  defp pool_rate(%{kind: :agent, lp_fee: rate}), do: rate
  defp pool_rate(pool), do: FeeSchedule.lane(pool.chain, :pool).rate

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
