defmodule Autolaunch.Exposure.Steps do
  @moduledoc """
  The wallet steps for one Exposure action on one week, built on the server
  from the chain at the latest block, for a signer the caller has already
  proved is one of the acting account's own wallets
  (`Autolaunch.Exposure.Series`).

  Five actions, each one review of the steps the wallet sends in turn:

    * `:buy` — an exact USDC approval to the Aerodrome router, then a swap of
      `amount` USDC for one token (`leg`) through its pool
    * `:sell` — an exact approval of that token to the router, then a swap of
      `amount` of it for USDC
    * `:deposit` — an exact stock approval to the factory, then
      `deposit(week, amount)` on the factory, which opens the week's series on
      its first deposit and mints the signer that many of each token
    * `:redeem` — `redeem(overnight, session)` on the series: equal amounts
      (whole pairs) at any time, any mix once the series has ended
    * `:settle` — `settle()` on the series, which applies every price that is
      due; open to anyone, and it never fails for being early or late

  The approval is always a step of its own, so it stays pressable once done.
  An action the chain's own state makes certain to fail (a deposit after the
  week's last close or past the cap, returning more than the wallet holds)
  comes back with `blocked` set to the reason and `approved` saying whether
  the allowance already covers it; its steps are still built, so a press the
  chain has since allowed reaches the wallet. A request that cannot name a
  real action (a zero amount, or a token of a week not open yet) is refused
  outright.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias Autolaunch.Exposure.{Chain, Deployment, Ledger}
  alias RegentChain.{Call, Review}

  @kinds [:buy, :sell, :deposit, :redeem, :settle]
  @usdc_decimals 6
  # A swap reverts rather than paying out less than its quote minus this, in basis points.
  @slippage_bps 200
  # How long after its review a swap may still land.
  @swap_window 20 * 60
  @swap "swapExactTokensForTokens(uint256,uint256,(address,address,bool,address)[],address,uint256)"

  def kinds, do: @kinds

  @type prepared :: %{
          kind: atom(),
          week: pos_integer(),
          chain: map(),
          steps: [map()],
          blocked: atom() | nil,
          approved: boolean(),
          facts: map()
        }

  @doc "The review for `request` on its week signed by `signer`, or why there can be none."
  @spec prepare(map(), String.t()) :: {:ok, prepared()} | {:error, atom()}
  def prepare(%{kind: kind, week: week} = request, signer) when kind in @kinds do
    with {:ok, config} <- Deployment.current(),
         {:ok, reading, block, opts} <- Chain.read_week(config, week),
         {:ok, built} <- build(kind, request, reading, config, signer, block, opts) do
      {:ok, Map.merge(built, %{kind: kind, week: reading.week, chain: Client.chain(config.lab)})}
    end
  end

  def prepare(_request, _signer), do: {:error, :unknown_action}

  # Before its first deposit a week has no series and no tokens: only a deposit names it.
  defp build(kind, _request, %{opened?: false}, _config, _signer, _block, _opts)
       when kind != :deposit,
       do: {:error, :week_not_open}

  defp build(kind, request, reading, config, signer, block, opts) when kind in [:buy, :sell],
    do: trade(kind, request, reading, config, signer, block, opts)

  defp build(:deposit, request, reading, config, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, wallet} <- Chain.holding(reading, config, signer, block, opts) do
      room = Chain.room(reading)

      {:ok,
       %{
         steps: [
           Review.step(
             "stock_approval",
             reading.stock.address,
             Abi.encode_erc20("approve", [config.factory, amount])
           ),
           Review.step(
             "deposit",
             config.factory,
             Call.encode("deposit(uint256,uint256)", [reading.week, amount])
           )
         ],
         blocked: deposit_blocked(reading, wallet, amount, room),
         approved: wallet.allowance >= amount,
         facts: %{amount: amount, room: room}
       }}
    end
  end

  defp build(:redeem, request, reading, config, signer, block, opts) do
    with {:ok, overnight, session} <- amounts(request),
         {:ok, wallet} <- Chain.holding(reading, config, signer, block, opts) do
      owed = owed(reading, overnight, session)
      paid = owed && Ledger.paid(owed, reading.held, reading.accounted)

      {:ok,
       %{
         steps: [
           Review.step(
             "redeem",
             reading.address,
             Call.encode("redeem(uint256,uint256)", [overnight, session])
           )
         ],
         blocked: redeem_blocked(wallet, {overnight, session}, owed, paid),
         approved: true,
         facts: %{overnight: overnight, session: session, paid: paid}
       }}
    end
  end

  defp build(:settle, _request, reading, _config, _signer, _block, _opts) do
    {:ok,
     %{
       steps: [Review.step("settle", reading.address, Call.encode("settle()", []))],
       blocked: nil,
       approved: true,
       facts: %{due: reading.waiting, ends: reading.end_waiting?, next: next(reading.next)}
     }}
  end

  defp next(nil), do: nil

  defp next(next),
    do: %{
      index: next.index,
      at: next.at,
      kind: if(next.open?, do: :open, else: :close),
      applies_at: next.due_at
    }

  # Every reason the factory's `deposit` would revert at the latest block: the
  # week is past its last close (or ended, or still waiting on its first
  # price), opening a new week is paused, the series holds less stock than it
  # owes, or the amount is past the cap, the wallet's stock or its allowance.
  defp deposit_blocked(reading, wallet, amount, room),
    do: week_blocked(reading) || amount_blocked(wallet, amount, room)

  defp week_blocked(%{current?: false}), do: :deposits_closed

  defp week_blocked(reading) do
    cond do
      reading.now >= List.last(reading.boundaries) -> :deposits_closed
      not reading.opened? and reading.paused -> :paused
      reading.status == :ended -> :ended
      reading.status == :pending -> :not_open
      reading.held < reading.accounted -> :backing_short
      true -> nil
    end
  end

  defp amount_blocked(wallet, amount, room) do
    cond do
      amount > room -> :above_cap
      wallet.stock < amount -> :not_enough_stock
      wallet.allowance < amount -> :approve_first
      true -> nil
    end
  end

  # A buy pays `amount` USDC into the token's pool; a sell pays `amount` of the
  # token. The quote is the pool's own; the swap takes nothing less than it
  # minus the slippage allowance, and only until its deadline.
  defp trade(kind, request, reading, config, signer, block, opts) do
    with {:ok, leg} <- leg(request[:leg]),
         {:ok, amount} <- positive(request[:amount]),
         {:ok, wallet} <- Chain.trade_position(reading, config, leg, signer, block, opts),
         side = side(kind, Map.fetch!(reading, leg).address, config, wallet),
         {:ok, out} <- quote(wallet.pool, amount, side.token_in, block, opts) do
      min_out = out && div(out * (10_000 - @slippage_bps), 10_000)
      route = {side.token_in, side.token_out, false, config.pool_factory}
      deadline = block.timestamp + @swap_window

      {:ok,
       %{
         steps: [
           Review.step(
             side.approval,
             side.token_in,
             Abi.encode_erc20("approve", [config.router, amount])
           ),
           Review.step(
             Atom.to_string(kind),
             config.router,
             Call.encode(@swap, [amount, min_out || 0, [route], signer, deadline])
           )
         ],
         blocked: trade_blocked(kind, out, side, amount),
         approved: side.allowance >= amount,
         facts: %{
           leg: leg,
           amount: amount,
           expected: out,
           minimum: min_out,
           usdc_decimals: @usdc_decimals,
           slippage_bps: @slippage_bps
         }
       }}
    end
  end

  # What a trade pays in and takes out, and what the wallet has of what it pays.
  defp side(:buy, token, config, wallet),
    do: %{
      token_in: config.usdc,
      token_out: token,
      held: wallet.usdc,
      allowance: wallet.usdc_allowance,
      approval: "usdc_approval"
    }

  defp side(:sell, token, config, wallet),
    do: %{
      token_in: token,
      token_out: config.usdc,
      held: wallet.leg,
      allowance: wallet.leg_allowance,
      approval: "token_approval"
    }

  defp trade_blocked(_kind, nil, _side, _amount), do: :no_liquidity
  defp trade_blocked(_kind, 0, _side, _amount), do: :too_small
  defp trade_blocked(:buy, _out, %{held: held}, amount) when held < amount, do: :not_enough_usdc
  defp trade_blocked(:sell, _out, %{held: held}, amount) when held < amount, do: :more_than_held

  defp trade_blocked(_kind, _out, %{allowance: allowance}, amount) when allowance < amount,
    do: :approve_first

  defp trade_blocked(_kind, _out, _side, _amount), do: nil

  defp quote(nil, _amount, _token_in, _block, _opts), do: {:ok, nil}

  defp quote(pool, amount, token_in, block, opts),
    do: Chain.amount_out(pool, amount, token_in, block, opts)

  defp leg(leg) when leg in [:overnight, :session], do: {:ok, leg}
  defp leg(_leg), do: {:error, :leg_required}

  # Before the end only whole pairs have a price; unequal amounts owe nothing yet.
  defp owed(%{status: :ended} = reading, overnight, session),
    do: Chain.owed(reading, overnight, session)

  defp owed(reading, pairs, pairs), do: Chain.owed(reading, pairs, pairs)
  defp owed(_reading, _overnight, _session), do: nil

  defp redeem_blocked(wallet, {overnight, session}, owed, paid) do
    cond do
      is_nil(owed) -> :pair_required
      overnight > wallet.overnight or session > wallet.session -> :more_than_held
      paid == 0 and owed != 0 -> :backing_short
      true -> nil
    end
  end

  defp amounts(%{overnight: overnight, session: session})
       when is_integer(overnight) and is_integer(session) and overnight >= 0 and session >= 0 and
              overnight + session > 0,
       do: {:ok, overnight, session}

  defp amounts(_request), do: {:error, :invalid_amount}

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: {:error, :invalid_amount}
end
