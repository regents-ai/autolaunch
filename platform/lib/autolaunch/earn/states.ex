defmodule Autolaunch.Earn.States do
  @moduledoc """
  Earn's state machines, each derived from the chain as read at one block and
  stored nowhere, so nothing can drift from it. Each has one function that
  derives a tagged value and is matched in full, with no catch-all; what a
  state allows is decided in one place (`allows?/2` for the market, `blocked/1`
  for a step). `platform/docs/earn-design.md` has a table for each.

    * market status (`status/1`): `:open`, `:frozen`, `:paused` or `:inactive`
    * deposit capacity (`capacity/1`): `:uncapped`, `{:left, units}` or `:full`
    * withdraw availability (`availability/2`): `:available` or
      `{:short, available_now}`
    * deposit readiness (`readiness/2`): `:needs_approval` or `:approved`
    * withdraw amount kind (`withdrawal/1`): `{:amount, units}` or `:everything`
    * position (`position/1`): `:none` or `{:held, balance}`
    * the blocked reason (`blocked/1`): `:ok` or `{:blocked, reason}`

  The amount a person types is its own machine (`Autolaunch.Earn.Amount`),
  kept apart from these: a figure that does not read is an input error, never a
  blocked step.
  """

  @kinds [:deposit, :withdraw]

  # What the pool's `withdraw` takes for "everything": it withdraws the whole
  # balance as it stands when the step lands, interest to that moment included.
  @everything 2 ** 256 - 1

  @ray 10 ** 27

  @type kind :: :deposit | :withdraw
  @type status :: :open | :frozen | :paused | :inactive
  @type capacity :: :uncapped | {:left, pos_integer()} | :full
  @type availability :: :available | {:short, non_neg_integer()}
  @type readiness :: :needs_approval | :approved
  @type withdrawal :: {:amount, pos_integer()} | :everything
  @type position :: :none | {:held, pos_integer()}
  @type reason ::
          :market_inactive
          | :market_paused
          | :market_frozen
          | :not_enough_usdc
          | :over_supply_cap
          | :over_balance
          | :not_available_now

  def kinds, do: @kinds

  @doc "The units the pool's `withdraw` is sent for a withdrawal."
  @spec withdraw_units(withdrawal()) :: pos_integer()
  def withdraw_units({:amount, units}), do: units
  def withdraw_units(:everything), do: @everything

  @doc """
  The market's status from its configuration flags. An inactive market takes
  nothing at all; a paused one neither deposits nor withdrawals; a frozen one
  takes no deposits but lets every balance out.
  """
  @spec status(%{active: boolean(), paused: boolean(), frozen: boolean()}) :: status()
  def status(%{active: false}), do: :inactive
  def status(%{active: true, paused: true}), do: :paused
  def status(%{active: true, paused: false, frozen: true}), do: :frozen
  def status(%{active: true, paused: false, frozen: false}), do: :open

  @doc "Whether a market in `status` takes a step of `kind`."
  @spec allows?(status(), kind()) :: boolean()
  def allows?(:open, kind) when kind in @kinds, do: true
  def allows?(:frozen, :deposit), do: false
  def allows?(:frozen, :withdraw), do: true
  def allows?(:paused, kind) when kind in @kinds, do: false
  def allows?(:inactive, kind) when kind in @kinds, do: false

  @doc """
  The most one deposit can be before the market's supply cap, worked out the
  way the pool checks it (`ValidationLogic.validateSupply`, Aave V3.5 on):
  every scaled balance, the treasury's scaled share and the deposit scaled
  down at the income `index` (`TokenMath.getATokenMintScaledAmount`,
  `rayDivFloor`), that sum's balance at `index` rounded down
  (`getATokenBalance`, `rayMulFloor`), at most `cap` whole tokens. `cap` is 0
  for none; `scaled` is the scaled balances and the treasury's share, as the
  chain holds them (`Autolaunch.Earn.Chain`).

  A deposit up to `left` passes that check at `index`; one more unit does not.
  """
  @spec capacity(%{
          cap: non_neg_integer(),
          decimals: non_neg_integer(),
          scaled: non_neg_integer(),
          index: pos_integer()
        }) :: capacity()
  def capacity(%{cap: 0}), do: :uncapped

  def capacity(%{cap: cap, decimals: decimals, scaled: scaled, index: index}) when cap > 0 do
    # The most scaled supply whose balance at `index`, rounded down, is within the cap.
    most = div((cap * 10 ** decimals + 1) * @ray - 1, index)

    # The largest deposit whose scaled amount, rounded down, still fits under it.
    case most - scaled do
      short when short < 0 -> :full
      fits -> left(div((fits + 1) * index - 1, @ray))
    end
  end

  defp left(0), do: :full
  defp left(units) when units > 0, do: {:left, units}

  @doc "Whether `units` can be withdrawn now, from the `liquidity` the market holds."
  @spec availability(pos_integer(), non_neg_integer()) :: availability()
  def availability(units, liquidity) when units <= liquidity, do: :available
  def availability(units, liquidity) when units > liquidity, do: {:short, liquidity}

  @doc """
  Whether a deposit of `units` can go straight to the pool: its USDC allowance
  must cover exactly that amount. An amount edited after an approval, or an
  allowance changed elsewhere, is read again each time.
  """
  @spec readiness(pos_integer(), non_neg_integer()) :: readiness()
  def readiness(units, allowance) when allowance >= units, do: :approved
  def readiness(units, allowance) when allowance < units, do: :needs_approval

  @doc """
  What a withdrawal asks for: `:everything` only when asked for by name (the
  page's Max), never an amount that happens to equal the balance, which can
  have grown by the time the step lands.
  """
  @spec withdrawal(:everything | pos_integer()) :: withdrawal()
  def withdrawal(:everything), do: :everything
  def withdrawal(units) when is_integer(units) and units > 0, do: {:amount, units}

  @doc """
  The wallet's position from its balance in the market. Any balance above
  zero is held, a dust balance of one unit included, and shows as its exact
  figure; only zero is none.
  """
  @spec position(non_neg_integer()) :: position()
  def position(0), do: :none
  def position(balance) when is_integer(balance) and balance > 0, do: {:held, balance}

  @doc """
  Whether a step is certain to fail, from the chain at the latest block, and
  why. The order is part of the contract: first the market's status, then what
  the wallet holds (its USDC for a deposit, its balance for a withdrawal), then
  what the market can take or give right now (its capacity under the supply
  cap, the USDC available). The first that fails is the reason.

  An approval still to land is not a reason: it is the deposit's readiness
  (`readiness/2`), a step of the review.
  """
  @spec blocked(%{
          required(:kind) => kind(),
          required(:status) => status(),
          optional(atom()) => term()
        }) :: :ok | {:blocked, reason()}
  def blocked(%{kind: kind, status: status} = facts) do
    with :ok <- market(status, kind),
         :ok <- held(kind, facts) do
      market_capacity(kind, facts)
    end
  end

  defp market(status, kind) do
    case {allows?(status, kind), status} do
      {true, _status} -> :ok
      {false, :inactive} -> {:blocked, :market_inactive}
      {false, :paused} -> {:blocked, :market_paused}
      {false, :frozen} -> {:blocked, :market_frozen}
    end
  end

  defp held(:deposit, %{units: units, funds: funds}) when units <= funds, do: :ok

  defp held(:deposit, %{units: units, funds: funds}) when units > funds,
    do: {:blocked, :not_enough_usdc}

  defp held(:withdraw, %{position: :none}), do: {:blocked, :over_balance}
  defp held(:withdraw, %{position: {:held, _balance}, withdrawal: :everything}), do: :ok

  defp held(:withdraw, %{position: {:held, balance}, withdrawal: {:amount, units}})
       when units <= balance,
       do: :ok

  defp held(:withdraw, %{position: {:held, balance}, withdrawal: {:amount, units}})
       when units > balance,
       do: {:blocked, :over_balance}

  defp market_capacity(:deposit, %{capacity: :uncapped}), do: :ok

  defp market_capacity(:deposit, %{capacity: {:left, left}, units: units}) when units <= left,
    do: :ok

  defp market_capacity(:deposit, %{capacity: {:left, left}, units: units}) when units > left,
    do: {:blocked, :over_supply_cap}

  defp market_capacity(:deposit, %{capacity: :full}), do: {:blocked, :over_supply_cap}

  defp market_capacity(:withdraw, %{position: {:held, balance}} = facts) do
    case availability(withdrawn(facts.withdrawal, balance), facts.liquidity) do
      :available -> :ok
      {:short, _available_now} -> {:blocked, :not_available_now}
    end
  end

  @doc """
  What a withdrawal takes out, as the chain reads it at one block: everything
  is the `balance` at that block, and a little more interest by the time it
  lands.
  """
  @spec withdrawn(withdrawal(), non_neg_integer()) :: non_neg_integer()
  def withdrawn(:everything, balance), do: balance
  def withdrawn({:amount, units}, _balance), do: units
end
