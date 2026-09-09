defmodule AutolaunchWeb.Components.PoolSection do
  @moduledoc """
  The "Pool" section of a graduated token's page: the pool a launch graduated
  into, its locked positions, its price, and its fee lanes and revenue, read from
  the local Base fork by `Autolaunch.Pool`.
  """
  use AutolaunchWeb, :html

  alias Autolaunch.Stocks.Amounts

  attr :pool, :any, required: true

  def pool_facts(assigns) do
    ~H"""
    <section id="pool" class="market-profile-panel pool-section" aria-label="Pool">
      <Regent.Structure.section_bar>
        <h2 class="rg-section-bar__label">Pool</h2>
      </Regent.Structure.section_bar>
      <p :if={@pool.loading} role="status">Reading the pool from the Base fork…</p>
      <div :if={@pool.failed} role="alert" class="autolaunch-empty">
        <p>{failure_copy(@pool.failed)}</p>
        <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
          Read again
        </Regent.Primitives.button>
      </div>
      <.facts :if={@pool.ok?} facts={@pool.result} />
    </section>
    """
  end

  attr :facts, :map, required: true

  defp facts(assigns) do
    ~H"""
    <p>
      {@facts.token.symbol} trades against {@facts.currency.symbol} in its official pool.
      Its liquidity is locked forever; the fee lanes below are charged on every trade.
    </p>
    <dl class="autolaunch-live-market pool-facts">
      <div>
        <dt>Pair</dt>
        <dd>
          {@facts.token.symbol} / {@facts.currency.symbol}
          <span class="autolaunch-exact-value">{@facts.token.symbol} {@facts.token.address}</span>
          <span class="autolaunch-exact-value">
            {@facts.currency.symbol} {@facts.currency.address}
          </span>
        </dd>
      </div>
      <div>
        <dt>Pool id</dt>
        <dd class="autolaunch-exact-value">{@facts.pool_id}</dd>
      </div>
      <div>
        <dt>Liquidity fee</dt>
        <dd>{@facts.lp_fee} · tick spacing {@facts.tick_spacing}</dd>
      </div>
      <div>
        <dt>Price at graduation</dt>
        <dd>
          {price(@facts.graduation_price)} {@facts.currency.symbol} per {@facts.token.symbol}
        </dd>
      </div>
      <div>
        <dt>Current price</dt>
        <dd :if={@facts.current}>
          {price(@facts.current.price)} {@facts.currency.symbol} per {@facts.token.symbol}
        </dd>
        <dd :if={!@facts.current}>Not readable right now</dd>
      </div>
      <div>
        <dt>Current liquidity</dt>
        <dd :if={@facts.current}>{Amounts.grouped(Integer.to_string(@facts.current.liquidity))}</dd>
        <dd :if={!@facts.current}>Not readable right now</dd>
      </div>
      <div>
        <dt>Unsold tokens</dt>
        <dd>
          {Amounts.compact_decimal(@facts.unsold.amount)} {@facts.token.symbol} {unsold_copy(
            @facts.unsold
          )}
          <span class="autolaunch-exact-value">{@facts.unsold.address}</span>
        </dd>
      </div>
      <div>
        <dt>Read at local block</dt>
        <dd>{@facts.block.number}</dd>
      </div>
    </dl>

    <h3>Locked liquidity</h3>
    <ol class="autolaunch-record-list pool-positions">
      <li :for={position <- @facts.positions}>
        <article>
          <h4>{position.label} position · NFT #{position.token_id}</h4>
          <dl class="autolaunch-live-market">
            <div>
              <dt>{@facts.token.symbol}</dt>
              <dd>{Amounts.compact_decimal(position.token_amount)}</dd>
            </div>
            <div>
              <dt>{@facts.currency.symbol}</dt>
              <dd>{Amounts.compact_decimal(position.currency_amount)}</dd>
            </div>
            <div>
              <dt>Owner</dt>
              <dd>
                <span class="autolaunch-exact-value">{position.owner}</span>
                <span :if={position.locked?}>Locked forever: nobody holds this address.</span>
              </dd>
            </div>
          </dl>
        </article>
      </li>
    </ol>

    <p>
      <a href={@facts.uniswap_url} target="_blank" rel="noopener noreferrer">
        Open this pool on the Uniswap app
      </a>
      · public Base mainnet link, not this fork
    </p>

    <Regent.Primitives.disclosure id="pool-exact-values" summary="Exact values">
      <dl class="autolaunch-live-market">
        <div>
          <dt>Price at graduation (every digit)</dt>
          <dd class="autolaunch-exact-value">{@facts.graduation_price.value}</dd>
        </div>
        <div :if={@facts.current}>
          <dt>Current price (every digit)</dt>
          <dd class="autolaunch-exact-value">{@facts.current.price.value}</dd>
        </div>
        <div :if={@facts.current}>
          <dt>Current sqrt price (X96)</dt>
          <dd class="autolaunch-exact-value">{@facts.current.sqrt_price_x96}</dd>
        </div>
        <div :if={@facts.current}>
          <dt>Current tick</dt>
          <dd class="autolaunch-exact-value">{@facts.current.tick}</dd>
        </div>
        <div :for={position <- @facts.positions}>
          <dt>{position.label} position (every digit)</dt>
          <dd class="autolaunch-exact-value">
            {position.token_amount} {@facts.token.symbol} · {position.currency_amount} {@facts.currency.symbol}
          </dd>
        </div>
        <div>
          <dt>Unsold tokens (every digit)</dt>
          <dd class="autolaunch-exact-value">{@facts.unsold.amount}</dd>
        </div>
        <div>
          <dt>Pool fee lane contract</dt>
          <dd class="autolaunch-exact-value">{@facts.hook}</dd>
        </div>
        <div>
          <dt>Pool manager</dt>
          <dd class="autolaunch-exact-value">{@facts.pool_manager}</dd>
        </div>
      </dl>
    </Regent.Primitives.disclosure>

    <.agent_fees :if={@facts.kind == :agent} facts={@facts} />
    <.stocks_fees :if={@facts.kind == :stocks} facts={@facts} />
    """
  end

  attr :facts, :map, required: true

  defp agent_fees(assigns) do
    ~H"""
    <section id="pool-fees" aria-label="Fee lanes">
      <h3>Fee lanes</h3>
      <p>
        1% of currency-side volume goes to REGENT (governance) and 1% to the subject's revenue
        splitter, paid on every trade. Fee lanes are fixed for this pool.
      </p>
      <dl class="autolaunch-live-market">
        <div>
          <dt>Subject revenue splitter</dt>
          <dd>
            <span class="autolaunch-exact-value">{@facts.fees.splitter}</span>
            <.link navigate={@facts.fees.subject_path}>Open the subject page</.link>
          </dd>
        </div>
        <div>
          <dt>Trades charged since graduation</dt>
          <dd>{@facts.fees.swaps}</dd>
        </div>
        <div>
          <dt>Paid to each lane so far</dt>
          <dd>
            {Amounts.compact_decimal(@facts.fees.per_lane.currency)} REGENT and {Amounts.compact_decimal(
              @facts.fees.per_lane.token
            )} {@facts.fees.token_symbol}
            <span class="autolaunch-exact-value">
              {@facts.fees.per_lane.currency} REGENT · {@facts.fees.per_lane.token} {@facts.fees.token_symbol}
            </span>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :facts, :map, required: true

  defp stocks_fees(assigns) do
    ~H"""
    <section id="pool-fees" aria-label="Fee lanes">
      <h3>Fee lanes</h3>
      <p>
        Two revenue lanes are charged in {@facts.currency.symbol} on every trade: 1% of
        currency-side volume for REGENT, always on, and 1% for the subject lane when it is on. {@facts.fees.trades} trades have been charged since graduation.
      </p>
      <dl class="autolaunch-live-market">
        <div>
          <dt>REGENT lane</dt>
          <dd>On · 1%</dd>
        </div>
        <div>
          <dt>Subject lane</dt>
          <dd :if={@facts.fees.config.splitter}>
            On · 1% to <span class="autolaunch-exact-value">{@facts.fees.config.splitter}</span>
          </dd>
          <dd :if={!@facts.fees.config.splitter}>Off</dd>
        </div>
      </dl>

      <h4>Revenue by destination</h4>
      <ol class="autolaunch-record-list pool-buckets">
        <li>
          <.bucket
            label="REGENT"
            bucket={@facts.fees.regent_bucket}
            currency={@facts.currency.symbol}
          />
        </li>
        <li :for={bucket <- @facts.fees.subject_buckets}>
          <.bucket
            label={
              if bucket.destination == @facts.fees.config.splitter,
                do: "Subject lane (current)",
                else: "Subject lane (earlier destination)"
            }
            bucket={bucket}
            currency={@facts.currency.symbol}
          />
        </li>
      </ol>
      <p>
        Revenue is converted to USDC and deposited by the operator outside trading.
        Operator account: <span class="autolaunch-exact-value">{@facts.fees.executor}</span>
      </p>

      <h4>Conversions so far</h4>
      <p :if={@facts.fees.settlements == []} class="autolaunch-empty">
        No revenue has been converted yet.
      </p>
      <ol :if={@facts.fees.settlements != []} class="autolaunch-record-list">
        <li :for={settlement <- @facts.fees.settlements}>
          <article>
            <dl class="autolaunch-live-market">
              <div>
                <dt>Destination</dt>
                <dd class="autolaunch-exact-value">{settlement.destination}</dd>
              </div>
              <div>
                <dt>Converted</dt>
                <dd>{Amounts.compact_decimal(settlement.currency)} {@facts.currency.symbol}</dd>
              </div>
              <div>
                <dt>Deposited</dt>
                <dd>{Amounts.compact_decimal(settlement.usdc)} USDC</dd>
              </div>
              <div>
                <dt>Block</dt>
                <dd>{settlement.block}</dd>
              </div>
              <div>
                <dt>Transaction</dt>
                <dd class="autolaunch-exact-value">{settlement.transaction_hash}</dd>
              </div>
            </dl>
          </article>
        </li>
      </ol>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :bucket, :map, required: true
  attr :currency, :string, required: true

  defp bucket(assigns) do
    ~H"""
    <article>
      <h5>{@label}</h5>
      <dl class="autolaunch-live-market">
        <div>
          <dt>Destination</dt>
          <dd class="autolaunch-exact-value">{@bucket.destination}</dd>
        </div>
        <div>
          <dt>Awaiting conversion</dt>
          <dd>{Amounts.compact_decimal(@bucket.accrued)} {@currency}</dd>
        </div>
        <div>
          <dt>Converted so far</dt>
          <dd>{Amounts.compact_decimal(@bucket.settled_currency)} {@currency}</dd>
        </div>
        <div>
          <dt>Deposited so far</dt>
          <dd>{Amounts.compact_decimal(@bucket.settled_usdc)} USDC</dd>
        </div>
      </dl>
    </article>
    """
  end

  defp price(%{value: value, exact?: true}), do: Amounts.compact_decimal(value)

  defp price(%{value: value, exact?: false}),
    do: value |> String.trim_trailing("…") |> Amounts.compact_decimal() |> mark()

  defp mark(value), do: if(String.ends_with?(value, "…"), do: value, else: value <> "…")

  defp unsold_copy(%{disposition: :retired}), do: "retired forever at"
  defp unsold_copy(%{disposition: :escrow}), do: "held by the launch's vesting escrow at"

  defp failure_copy({:error, :not_graduated}), do: "This launch has not graduated into a pool."

  defp failure_copy({:error, reason}) when reason in [:lab_disabled, :stocks_lab_disabled],
    do: "Pool details are read from a Base fork, and this site is not running one."

  defp failure_copy(_reason),
    do: "The pool could not be read from the Base fork just now."
end
