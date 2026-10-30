defmodule AutolaunchWeb.ExposureAnswer do
  @moduledoc """
  The Exposure answers every HTTP route gives (`AutolaunchWeb.ExposureController`,
  `AutolaunchWeb.ExposureAgentController`), so the public, signed-in and
  signed-agent doors share one shape and one set of refusals. The figures come
  unchanged from `Autolaunch.Exposure`: stock and leg amounts in raw token
  units, prices and ledgers in WAD (18-decimal) dollars per stock token, pool
  quotes in micro-USDC (6 decimals), times in Unix seconds.

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered 200 with `blocked` naming the reason, beside the steps themselves.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.Exposure
  alias AutolaunchWeb.ApiError

  @integer_fields ~w(amount overnight session)

  @blocked %{
    not_open: "Minting opens once the series has applied its first close.",
    ended: "This series has ended.",
    above_cap: "This amount would take the series past its deposit cap.",
    backing_short:
      "The series holds less stock than it owes, after the stock's issuer took some, so it takes no new deposits and this return would pay nothing.",
    not_enough_stock: "This wallet holds less of the stock than the amount to mint.",
    approve_first:
      "Approve the amount first; the next step can be sent once the approval is on the chain.",
    pair_required: "Until the series ends, only equal amounts of each token can be returned.",
    more_than_held: "This wallet holds less of a token than the amount to return.",
    too_early: "The next price can be recorded only from an hour after its time.",
    price_too_old:
      "The feed had no price in the 84 hours before this moment, so it can never be recorded; the series can be ended once its recording window has passed.",
    missed_deadline:
      "The recording window for the next price has passed, so it can no longer be applied; the series can be ended.",
    price_available: "The next price was recorded in time, so the series cannot be ended for it.",
    not_overdue: "The recording window for the next price is still open."
  }

  @refusals %{
    unknown_series:
      {:not_found,
       "There is no Isolated Exposure to After-hours Stocks series at that address on this site."},
    unknown_terms:
      {:not_found,
       "There are no Isolated Exposure to After-hours Stocks terms with that fingerprint on this site."},
    invalid_amount:
      {:unprocessable_entity,
       "Send each amount as a whole number of raw units, above zero in total."},
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields: kind as text, a signer address as text, and every amount as a whole number."},
    wrong_signer: {:forbidden, "That wallet is not one of this account's own wallets."},
    wallet_required: {:conflict, "This account has no wallet to act with."},
    authentication_required: {:unauthorized, "Nobody is signed in on this site in this browser."},
    chain_unavailable:
      {:service_unavailable,
       "Isolated Exposure to After-hours Stocks could not be read from the chain just now."}
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
  defp prepare_field?({key, value}) when key in @integer_fields, do: is_integer(value)
  defp prepare_field?(_field), do: false

  # Inputs the action itself refuses (a kind it does not know, a negative
  # amount) are the caller's to fix; a refusal the operation names keeps its
  # own reason.
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request
  defp reason(error), do: Exposure.reason(error)

  defp present(:list, list), do: Enum.map(list, &present(:series, &1))

  defp present(:series, series) do
    %{
      address: series.address,
      block: series.block,
      now: series.now,
      read_at: series.read_at,
      stock: series.stock,
      after_hours:
        Map.merge(series.overnight, %{
          ledger: series.night,
          supply: series.supply.overnight,
          pool: series.pools.overnight
        }),
      market_hours:
        Map.merge(series.session, %{
          ledger: series.day,
          supply: series.supply.session,
          pool: series.pools.session
        }),
      oracle: series.oracle,
      feed: series.feed,
      feed_phase: series.phase,
      terms_hash: series.terms_hash,
      terms_url: AutolaunchWeb.Endpoint.url() <> "/after-hour-stocks/terms/" <> series.terms_hash,
      status: series.status,
      end_reason: series.end_reason,
      price: series.price,
      deposit_cap: series.deposit_cap,
      deposited: series.accounted,
      held: series.held,
      max_report_delay: series.max_report_delay,
      schedule:
        Enum.with_index(
          series.boundaries,
          &%{index: &2, at: &1, kind: if(rem(&2, 2) == 1, do: :open, else: :close)}
        ),
      prints: Enum.map(series.prints, &print/1),
      next: next(series.next)
    }
  end

  defp present(:holdings, holdings) do
    %{
      series: holdings.series.address,
      wallet: holdings.wallet,
      read_at: holdings.read_at,
      after_hours: holdings.overnight,
      market_hours: holdings.session,
      stock: holdings.stock,
      stock_allowance: holdings.allowance,
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
      signer: prepared.signer,
      chain: prepared.chain,
      steps: prepared.steps,
      approved: prepared.approved,
      blocked: blocked(prepared.blocked),
      facts: prepared.facts
    }
  end

  defp next(nil), do: nil

  defp next(next) do
    %{
      index: next.index,
      at: next.at,
      kind: if(next.open?, do: :open, else: :close),
      recordable_at: next.recordable_at,
      deadline: next.deadline
    }
  end

  defp print(print) do
    %{
      index: print.index,
      at: print.at,
      kind: if(print.open?, do: :open, else: :close),
      price: print.price,
      after_hours: print.night,
      market_hours: print.day,
      feed_round_id: print.round_id,
      feed_updated_at: print.updated_at,
      recorded_at: print.finalized_at
    }
  end

  defp blocked(nil), do: nil
  defp blocked(reason), do: %{code: reason, message: Map.fetch!(@blocked, reason)}
end
