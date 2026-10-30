defmodule AutolaunchWeb.CoveredCallsAnswer do
  @moduledoc """
  The covered-call answers every HTTP route gives (`AutolaunchWeb.CoveredCallsController`,
  `AutolaunchWeb.CoveredCallsAgentController`): the answer the operation built
  (`Autolaunch.CoveredCalls.Answer`) as `data`, or its refusal with its status
  and words. The hosted MCP tools give the same refusals in the same words
  (`body/1`, through `AutolaunchWeb.ToolErrors`).
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.CoveredCalls
  alias AutolaunchWeb.ApiError

  @integer_fields ~w(listing_id amount strike_per_token premium_per_token expiry)

  @chain_unavailable {:service_unavailable,
                      "Covered calls could not be read from the chain just now."}

  @refusals %{
    unknown_market: {:not_found, "There is no covered-call market for that stock."},
    unknown_listing: {:not_found, "There is no listing with that number on this market."},
    invalid_amount: {:unprocessable_entity, "Send each amount as a whole number above zero."},
    not_a_weekly_expiry:
      {:unprocessable_entity,
       "The expiry must be a Friday at 21:00 UTC, given as Unix time in seconds."},
    expiry_passed: {:unprocessable_entity, "That expiry has already passed."},
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields: kind as text, a signer address as text, and every amount, listing and expiry as a whole number."},
    wrong_signer: {:forbidden, "That wallet is not one of this account's own wallets."},
    wallet_required: {:conflict, "This account has no wallet to act with."},
    authentication_required: {:unauthorized, "Nobody is signed in on this site in this browser."},
    price_unavailable:
      {:service_unavailable,
       "The stock's reference price is not available right now, so no premium is suggested."},
    chain_unavailable: @chain_unavailable,
    # The node answered something that is not Base or not a block: to an agent,
    # the chain could not be read just now.
    invalid_chain_response: @chain_unavailable,
    invalid_block_header: @chain_unavailable,
    wrong_chain: @chain_unavailable
  }

  @doc "Answers with the operation's answer, or with the refusal it carries."
  def send(conn, {:ok, answer}), do: json(conn, %{data: answer})
  def send(conn, {:error, error}), do: refuse(conn, reason(error))

  @doc "Answers with the refusal named `reason`."
  def refuse(conn, reason) do
    {status, message} = Map.fetch!(@refusals, reason)
    ApiError.send(conn, status, Atom.to_string(reason), message)
  end

  @doc "The error document of the refusal named `reason`, as the routes send it."
  def body(reason) do
    {_status, message} = Map.fetch!(@refusals, reason)
    ApiError.body(Atom.to_string(reason), message)
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

  # Inputs the action itself refuses (a kind it does not know, an amount below
  # one) are the caller's to fix; a refusal the operation names keeps its own
  # reason.
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request
  defp reason(error), do: CoveredCalls.reason(error)
end
