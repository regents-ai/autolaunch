defmodule Autolaunch.Exposure.Steps do
  @moduledoc """
  The wallet steps for one Exposure action, built on the server from the chain
  at the latest block, for a signer the caller has already proved is one of the
  acting account's own wallets (`Autolaunch.Exposure.Series`).

  Four actions, each one review of the steps the wallet sends in turn:

    * `:mint` — an exact stock approval, then `mint(amount)`
    * `:redeem` — `redeem(overnight, session)`: equal amounts (whole pairs)
      before the series ends, any mix after it
    * `:update` — `record` the next price on the oracle when it is not yet
      recorded, then `settle` it into the series; open to anyone
    * `:end` — `endOnMissingPrint()`, once the next price can no longer be
      recorded in time; open to anyone

  The approval is always a step of its own, so it stays pressable once done.
  An action the chain's own state makes certain to fail (minting before the
  first close or past the cap, returning more than the wallet holds, a price
  not yet recordable) comes back with `blocked` set to the reason and
  `approved` saying whether the allowance already covers it; its steps are
  still built whenever they can be, so a press the chain has since allowed
  reaches the wallet. A request that cannot name a real action (a zero amount)
  is refused outright.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias Autolaunch.Exposure.{Chain, Deployment, Ledger}
  alias RegentChain.{Call, Review}

  @kinds [:mint, :redeem, :update, :end]
  # A recorded price may be at most this old at its moment (ChainlinkPrintOracleV2.MAX_STALENESS).
  @max_staleness 84 * 3_600

  def kinds, do: @kinds

  @type prepared :: %{
          kind: atom(),
          chain: map(),
          steps: [map()],
          blocked: atom() | nil,
          approved: boolean(),
          facts: map()
        }

  @doc "The review for `request` on `series` signed by `signer`, or why there can be none."
  @spec prepare(map(), String.t()) :: {:ok, prepared()} | {:error, atom()}
  def prepare(%{kind: kind, series: address} = request, signer) when kind in @kinds do
    with {:ok, config} <- Deployment.current(),
         {:ok, address} <- Deployment.series(address),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, series} <- Chain.series(address, config, block, opts),
         {:ok, built} <- build(kind, request, series, signer, block, opts) do
      {:ok, Map.merge(built, %{kind: kind, chain: Client.chain(config.lab)})}
    end
  end

  def prepare(_request, _signer), do: {:error, :unknown_action}

  defp build(:mint, request, series, signer, block, opts) do
    with {:ok, amount} <- positive(request[:amount]),
         {:ok, wallet} <- Chain.holdings(series, signer, block, opts) do
      room = max(series.deposit_cap - series.accounted, 0)

      blocked =
        cond do
          series.status == :pending -> :not_open
          series.status == :ended -> :ended
          series.held < series.accounted -> :backing_short
          amount > room -> :above_cap
          wallet.stock < amount -> :not_enough_stock
          wallet.allowance < amount -> :approve_first
          true -> nil
        end

      {:ok,
       %{
         steps: [
           Review.step(
             "stock_approval",
             series.stock.address,
             Abi.encode_erc20("approve", [series.address, amount])
           ),
           Review.step("mint", series.address, Call.encode("mint(uint256)", [amount]))
         ],
         blocked: blocked,
         approved: wallet.allowance >= amount,
         facts: %{amount: amount, room: room}
       }}
    end
  end

  defp build(:redeem, request, series, signer, block, opts) do
    with {:ok, overnight, session} <- amounts(request),
         {:ok, wallet} <- Chain.holdings(series, signer, block, opts) do
      owed = owed(series, overnight, session)
      paid = owed && Ledger.paid(owed, series.held, series.accounted)

      {:ok,
       %{
         steps: [
           Review.step(
             "redeem",
             series.address,
             Call.encode("redeem(uint256,uint256)", [overnight, session])
           )
         ],
         blocked: redeem_blocked(wallet, {overnight, session}, owed, paid),
         approved: true,
         facts: %{overnight: overnight, session: session, paid: paid}
       }}
    end
  end

  defp build(:update, _request, %{next: nil}, _signer, _block, _opts),
    do: {:ok, %{steps: [], blocked: :ended, approved: true, facts: %{}}}

  defp build(:update, _request, %{next: next} = series, _signer, block, opts) do
    with {:ok, print} <- Chain.recorded(series, next.at, next.index, block, opts) do
      cond do
        not next.due? ->
          {:ok, update([settle(series)], :too_early, next, nil)}

        print.price != 0 ->
          {:ok, update([settle(series)], late(print, next), next, print)}

        block.timestamp > next.deadline ->
          {:ok, update([settle(series)], :missed_deadline, next, nil)}

        true ->
          record(series, next, block, opts)
      end
    end
  end

  defp build(:end, _request, %{next: nil}, _signer, _block, _opts),
    do: {:ok, %{steps: [], blocked: :ended, approved: true, facts: %{}}}

  defp build(:end, _request, %{next: next} = series, _signer, block, opts) do
    with {:ok, print} <- Chain.recorded(series, next.at, next.index, block, opts) do
      blocked =
        cond do
          print.price != 0 and print.finalized_at <= next.deadline -> :price_available
          block.timestamp <= next.deadline -> :not_overdue
          true -> nil
        end

      {:ok,
       %{
         steps: [Review.step("end", series.address, Call.encode("endOnMissingPrint()", []))],
         blocked: blocked,
         approved: true,
         facts: %{at: next.at, deadline: next.deadline}
       }}
    end
  end

  # Before the end only whole pairs have a price; unequal amounts owe nothing yet.
  defp owed(%{status: :ended} = series, overnight, session),
    do: Chain.owed(series, overnight, session)

  defp owed(series, pairs, pairs), do: Chain.owed(series, pairs, pairs)
  defp owed(_series, _overnight, _session), do: nil

  defp redeem_blocked(wallet, {overnight, session}, owed, paid) do
    cond do
      is_nil(owed) -> :pair_required
      overnight > wallet.overnight or session > wallet.session -> :more_than_held
      paid == 0 and owed != 0 -> :backing_short
      true -> nil
    end
  end

  # A price recorded after its deadline can never be applied.
  defp late(%{finalized_at: at}, %{deadline: deadline}) when at > deadline, do: :missed_deadline
  defp late(_print, _next), do: nil

  # The round of the pinned feed phase in force at the price's moment; a round
  # older than the oracle accepts can never be recorded.
  defp record(series, next, block, opts) do
    case Chain.round_in_force(series, next.at, block, opts) do
      {:ok, %{round: round, updated_at: updated_at}} ->
        step =
          Review.step(
            "record",
            series.oracle,
            Call.encode("record(uint64,bool,uint64)", [next.at, next.open?, round])
          )

        blocked = if next.at - updated_at > @max_staleness, do: :price_too_old

        {:ok,
         update([step, settle(series)], blocked, next, %{round: round, updated_at: updated_at})}

      {:error, :no_round} ->
        {:ok, update([settle(series)], :price_too_old, next, nil)}

      error ->
        error
    end
  end

  defp settle(series), do: Review.step("settle", series.address, Call.encode("settle()", []))

  defp update(steps, blocked, next, source),
    do: %{
      steps: steps,
      blocked: blocked,
      approved: true,
      facts: %{
        at: next.at,
        kind: if(next.open?, do: :open, else: :close),
        recordable_at: next.recordable_at,
        source: source && Map.take(source, [:round, :round_id, :updated_at, :price])
      }
    }

  defp amounts(%{overnight: overnight, session: session})
       when is_integer(overnight) and is_integer(session) and overnight >= 0 and session >= 0 and
              overnight + session > 0,
       do: {:ok, overnight, session}

  defp amounts(_request), do: {:error, :invalid_amount}

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: {:error, :invalid_amount}
end
