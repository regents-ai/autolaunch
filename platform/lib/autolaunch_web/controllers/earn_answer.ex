defmodule AutolaunchWeb.EarnAnswer do
  @moduledoc """
  The Earn answers every HTTP route gives (`AutolaunchWeb.EarnController`,
  `AutolaunchWeb.EarnAgentController`): the answer the operation built
  (`Autolaunch.Earn.Answer`) as `data`, or its refusal with its status and
  words. The hosted MCP tools give the same refusals in the same words
  (`body/1`, through `AutolaunchWeb.ToolErrors`).
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.Earn
  alias AutolaunchWeb.ApiError

  @chain_unavailable {:service_unavailable, "Earn could not be read from the chain just now."}

  @refusals %{
    unknown_product: {:not_found, "There is no Earn product with that id."},
    invalid_amount:
      {:unprocessable_entity,
       "Send amount as a whole number of the asset's smallest units above zero, or, to withdraw the whole balance, everything as true and no amount."},
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields: product, kind and signer as text, amount as a whole number, and everything as true or false."},
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

  @fields %{
    "product" => &is_binary/1,
    "kind" => &is_binary/1,
    "signer" => &is_binary/1,
    "amount" => &is_integer/1,
    "everything" => &is_boolean/1
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
  A quote's or step's request body as the action's product, kind and other
  inputs, or `:error` when it leaves out the product or kind, or names a field
  the action does not take or gives one the wrong type.
  """
  def input(%{"product" => product, "kind" => kind} = body) do
    if Enum.all?(body, fn {key, value} -> is_map_key(@fields, key) and @fields[key].(value) end),
      do: {:ok, product, kind, Map.drop(body, ["product", "kind"])},
      else: :error
  end

  def input(_body), do: :error

  # Inputs the action itself refuses (a kind it does not know, an amount below
  # one) are the caller's to fix; a refusal the operation names keeps its own
  # reason.
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request
  defp reason(error), do: Earn.reason(error)
end
