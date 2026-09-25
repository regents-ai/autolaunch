defmodule AutolaunchWeb.Components.StakeSummary do
  @moduledoc """
  A launched token's staking at a glance: how much of its whole supply is
  staked, as a meter, and the trading fees its pool has charged over the last
  day and all time.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{TokenDisplay, UsdValue}

  attr :id, :string, required: true
  attr :pool, :map, required: true, doc: "the token's pool facts"
  attr :supply, :any, required: true, doc: "the token's whole supply in whole tokens, or nil"
  attr :label, :string, required: true, doc: "what staking this token is called"
  attr :fees, :map, required: true, doc: "`Autolaunch.PoolFees.totals/2` for the pool"
  attr :rate, :any, default: nil, doc: "the pool currency's dollar price, when known"

  def stake_summary(assigns) do
    %{pool: pool, supply: supply} = assigns
    staked = pool.fees.splitter.total_staked

    assigns =
      assign(assigns,
        staked_bps:
          staked_bps(pool.fees.splitter.total_staked_atomic, supply, pool.token.decimals),
        of_supply: supply && "#{tokens(staked)} of #{tokens(Decimal.to_string(supply, :normal))}"
      )

    ~H"""
    <Regent.Structure.ratio_card
      id={@id}
      class="stake-summary"
      eyebrow={@label}
      title={"#{@pool.token.symbol} staked"}
      value_bps={@staked_bps}
      label="Staked"
      remainder_label="Not staked"
      change={@of_supply && "#{@of_supply} #{@pool.token.symbol}"}
      footer_label="Trading fees"
    >
      <:footer>
        <dl class="stake-summary__fees">
          <div>
            <dt>Last 24 hours</dt>
            <dd>
              <.fee amount={@fees.day} pool={@pool} rate={@rate} />
            </dd>
          </div>
          <div>
            <dt>All time</dt>
            <dd>
              <.fee amount={@fees.all_time} pool={@pool} rate={@rate} />
            </dd>
          </div>
        </dl>
      </:footer>
    </Regent.Structure.ratio_card>
    """
  end

  attr :amount, :map, required: true
  attr :pool, :map, required: true
  attr :rate, :any, required: true

  # A fee total in the pool's currency, with its dollar value, and in the
  # token as well for a pool that also charged fees in it.
  defp fee(%{amount: nil} = assigns) do
    ~H"""
    <span class="stake-summary__pending">Counting trades…</span>
    """
  end

  defp fee(assigns) do
    ~H"""
    <strong>
      <TokenDisplay.price amount={@amount.currency} unit={@pool.currency.symbol} round={:down} />
    </strong>
    <span :if={zero?(@amount.token)}><UsdValue.usd amount={@amount.currency} rate={@rate} /></span>
    <strong :if={!zero?(@amount.token)}>
      + <TokenDisplay.price amount={@amount.token} unit={@pool.token.symbol} round={:down} />
    </strong>
    """
  end

  # Floored, so the meter never shows more staked than there is.
  defp staked_bps(_staked, nil, _decimals), do: nil

  defp staked_bps(staked, supply, decimals) do
    whole = supply |> Decimal.mult(Integer.pow(10, decimals)) |> Decimal.to_integer()
    if whole > 0, do: min(div(staked * 10_000, whole), 10_000)
  end

  defp tokens(amount), do: amount |> TokenDisplay.short(:down) |> Amounts.grouped()

  defp zero?(amount), do: Decimal.eq?(Decimal.new(amount), 0)
end
