defmodule Autolaunch.Earn.States do
  @moduledoc """
  Earn's state machines, each derived from the chain as read at one block and
  stored nowhere, so nothing can drift from it. Each has one function that
  derives a tagged value and is matched in full, with no catch-all; what a
  state allows is decided in one place (`allows?/2` for the market, `blocked/1`
  for a step). `platform/docs/earn-design.md` has a table for each.

    * market status (`status/1`): `:open`, `:frozen`, `:paused` or `:inactive`
    * deposit room (`room/1`): `:uncapped`, `{:room, units}` or `:full`
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

  @type kind :: :deposit | :withdraw
  @type status :: :open | :frozen | :paused | :inactive
  @type room :: :uncapped | {:room, pos_integer()} | :full
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
  How much more the market takes before its supply cap. `cap` is in whole
  tokens (0 for none); `counted` is what the pool counts against it: every
  supplied balance and the interest set aside for its treasury, at the block's
  index (`Autolaunch.Earn.Chain`). A deposit is refused once the counted total
  with it would pass `cap` whole tokens.
  """
  @spec room(%{cap: non_neg_integer(), decimals: non_neg_integer(), counted: non_neg_integer()}) ::
          room()
  def room(%{cap: 0}), do: :uncapped

  def room(%{cap: cap, decimals: decimals, counted: counted}) when cap > 0 do
    case cap * 10 ** decimals - counted do
      left when left > 0 -> {:room, left}
      left when left <= 0 -> :full
    end
  end

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
  what the market can take or give right now (the supply cap's room, the USDC
  available). The first that fails is the reason.

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
      market_room(kind, facts)
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

  defp market_room(:deposit, %{room: :uncapped}), do: :ok
  defp market_room(:deposit, %{room: {:room, left}, units: units}) when units <= left, do: :ok

  defp market_room(:deposit, %{room: {:room, left}, units: units}) when units > left,
    do: {:blocked, :over_supply_cap}

  defp market_room(:deposit, %{room: :full}), do: {:blocked, :over_supply_cap}

  defp market_room(:withdraw, %{position: {:held, balance}} = facts) do
    case availability(withdrawn(facts.withdrawal, balance), facts.liquidity) do
      :available -> :ok
      {:short, _available_now} -> {:blocked, :not_available_now}
    end
  end

  # What a withdrawal takes out, as the chain reads it now: everything is the
  # balance at this block.
  defp withdrawn(:everything, balance), do: balance
  defp withdrawn({:amount, units}, _balance), do: units
end
