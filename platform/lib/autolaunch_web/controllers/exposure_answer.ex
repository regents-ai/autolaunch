defmodule AutolaunchWeb.ExposureAnswer do
  @moduledoc """
  The Exposure answers every HTTP route gives (`AutolaunchWeb.ExposureController`,
  `AutolaunchWeb.ExposureAgentController`), so the public, signed-in and
  signed-agent doors share one shape and one set of refusals. The figures come
  unchanged from `Autolaunch.Exposure`: stock and token amounts in raw token
  units, prices and ledgers in WAD (18-decimal) dollars per stock token, pool
  quotes in micro-USDC (6 decimals), times in Unix seconds. A week is the
  factory's week number.

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered 200 with `blocked` naming the reason, beside the steps themselves.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.Exposure
  alias AutolaunchWeb.ApiError

  @integer_fields ~w(amount overnight session)

  @blocked %{
    too_small: "This amount is too small for the pool to pay anything back.",
    no_liquidity:
      "This token's pool has no liquidity yet, so it can't be bought or sold until liquidity is added.",
    not_enough_usdc: "This wallet holds less USDC than the amount to spend.",
    deposits_closed:
      "Deposits for this week have closed. The next week takes deposits from an hour after the week's last close.",
    paused: "Opening new weeks is paused, so this week can't open with a deposit now.",
    not_open: "This week takes deposits once its first price, the previous close, is applied.",
    ended: "This week has ended.",
    above_cap: "This amount would take the week past its deposit cap.",
    backing_short:
      "The series holds less stock than it owes, after the stock's issuer took some, so it takes no new deposits and this return would pay nothing.",
    not_enough_stock: "This wallet holds less of the stock than the amount to deposit.",
    approve_first:
      "Approve the amount first; the next step can be sent once the approval is on the chain.",
    pair_required: "Until the week ends, only equal amounts of each token can be redeemed.",
    more_than_held: "This wallet holds less of a token than the amount to redeem or sell."
  }

  @chain_unavailable {:service_unavailable,
                      "Isolated Exposure to After-hours Stocks could not be read from the chain just now."}

  @refusals %{
    unknown_week:
      {:not_found,
       "That week of Isolated Exposure to After-hours Stocks is neither this week nor one that has opened."},
    week_not_open:
      {:conflict,
       "This week has not opened yet: its tokens exist once its first deposit opens it."},
    unknown_terms:
      {:not_found,
       "There are no Isolated Exposure to After-hours Stocks terms with that fingerprint on this site."},
    leg_required: {:unprocessable_entity, "Name the token to buy or sell: overnight or session."},
    invalid_amount:
      {:unprocessable_entity,
       "Send each amount as a whole number of raw units, above zero in total."},
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields: kind as text, a signer address as text, and every amount as a whole number."},
    wrong_signer: {:forbidden, "That wallet is not one of this account's own wallets."},
    wallet_required: {:conflict, "This account has no wallet to act with."},
    authentication_required: {:unauthorized, "Nobody is signed in on this site in this browser."},
    chain_unavailable: @chain_unavailable,
    # The node answered something that is not Base or not a block: to an agent,
    # the chain could not be read just now.
    invalid_chain_response: @chain_unavailable,
    invalid_block_header: @chain_unavailable,
    wrong_chain: @chain_unavailable
  }

  @doc "Answers with `result`'s figures shaped by `shape`, or with the refusal it carries."
  def send(conn, {:ok, result}, shape), do: json(conn, %{data: present(shape, result)})
  def send(conn, {:error, error}, _shape), do: refuse(conn, reason(error))

  @doc "Answers with the refusal named `reason`."
  def refuse(conn, reason) do
    {status, message} = Map.fetch!(@refusals, reason)
    ApiError.send(conn, status, Atom.to_string(reason), message)
  end

  @doc """
  A step request's body as the prepare action's inputs, or `:error` when it
  names a field the action does not take or gives one the wrong type.
  """
  def prepare_input(%{"kind" => kind} = body) when is_binary(kind) do
    if Enum.all?(body, &prepare_field?/1),
      do:
        {:ok,
         body
         |> Map.delete("kind")
         |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)},
      else: :error
  end

  def prepare_input(_body), do: :error

  defp prepare_field?({"kind", value}), do: is_binary(value)
  defp prepare_field?({"signer", value}), do: is_binary(value)
  defp prepare_field?({"leg", value}), do: value in ["overnight", "session"]
  defp prepare_field?({key, value}) when key in @integer_fields, do: is_integer(value)
  defp prepare_field?(_field), do: false

  # Inputs the action itself refuses (a kind it does not know, a negative
  # amount, a week that is not a number) are the caller's to fix; a refusal
  # the operation names keeps its own reason.
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request
  defp reason(error), do: Exposure.reason(error)

  defp present(:list, list) do
    %{
      factory: list.factory,
      current_week: list.current_week,
      opening_paused: list.paused,
      read_at: list.read_at,
      weeks: Enum.map(list.weeks, &week/1)
    }
  end

  defp present(:week, reading),
    do: reading |> week() |> Map.put(:prices, prices(reading.prints))

  defp present(:holdings, holdings) do
    %{
      week: holdings.week.week,
      series: holdings.week.address,
      wallet: holdings.wallet,
      read_at: holdings.read_at,
      after_hours: holdings.overnight,
      market_hours: holdings.session,
      stock: holdings.stock,
      stock_allowance: holdings.allowance,
      usdc: holdings.usdc,
      returnable: %{
        after_hours: holdings.redeemable.overnight,
        market_hours: holdings.redeemable.session,
        stock: holdings.redeemable.paid
      }
    }
  end

  defp present(:prepare, prepared) do
    %{
      kind: prepared.kind,
      week: prepared.week,
      signer: prepared.signer,
      chain: prepared.chain,
      steps: prepared.steps,
      approved: prepared.approved,
      blocked: blocked(prepared.blocked),
      facts: prepared.facts
    }
  end

  defp week(reading) do
    %{
      week: reading.week,
      current: reading.current?,
      opened: reading.opened?,
      series: reading.address,
      factory: reading.factory,
      block: reading.block,
      now: reading.now,
      read_at: reading.read_at,
      stock: reading.stock,
      after_hours:
        Map.merge(reading.overnight, %{
          ledger: reading.night,
          supply: reading.supply.overnight,
          pool: reading.pools.overnight
        }),
      market_hours:
        Map.merge(reading.session, %{
          ledger: reading.day,
          supply: reading.supply.session,
          pool: reading.pools.session
        }),
      feed: reading.feed,
      feed_phase: reading.phase,
      terms_hash: reading.terms_hash,
      terms_url: terms_url(reading.terms_hash),
      status: reading.status,
      end_reason: reading.end_reason,
      price: reading.price,
      deposit_cap: reading.deposit_cap,
      deposited: reading.accounted,
      held: reading.held,
      opening_paused: reading.paused,
      prices_applied: reading.applied,
      prices_waiting: reading.waiting,
      feed_unreadable: reading.unreadable?,
      feed_unreadable_since: reading.unreadable_since,
      schedule:
        Enum.with_index(
          reading.boundaries,
          &%{
            index: &2,
            at: &1,
            kind: kind(rem(&2, 2) == 1),
            applies_at: &1 + Exposure.Chain.settle_delay()
          }
        ),
      next:
        reading.next &&
          %{
            index: reading.next.index,
            at: reading.next.at,
            kind: kind(reading.next.open?),
            applies_at: reading.next.due_at
          }
    }
  end

  # The terms are linked only when the site has their text.
  defp terms_url(hash) do
    if match?({:ok, _text}, Exposure.terms(hash)),
      do: AutolaunchWeb.Endpoint.url() <> "/stock/isolated-afters/terms/" <> hash
  end

  # Nil when the feed refused a read of a round the series applied.
  defp prices(nil), do: nil

  defp prices(prints) do
    Enum.map(prints, fn print ->
      %{
        index: print.index,
        at: print.at,
        kind: kind(print.open?),
        price: print.price,
        after_hours: print.night,
        market_hours: print.day,
        feed_round_id: print.round_id,
        feed_updated_at: print.updated_at
      }
    end)
  end

  defp kind(true), do: :open
  defp kind(false), do: :close

  defp blocked(nil), do: nil
  defp blocked(reason), do: %{code: reason, message: Map.fetch!(@blocked, reason)}
end
