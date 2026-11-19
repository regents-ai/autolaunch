defmodule AutolaunchWeb.AgentPaymentAnswer do
  @moduledoc """
  The agent payment answers the HTTP route gives
  (`AutolaunchWeb.AgentPaymentController`): the answer the operation built
  (`Autolaunch.AgentPayment`) as `data`, or its refusal with its status and
  words. The hosted MCP tool gives the same refusals in the same words
  (`body/1`, through `AutolaunchWeb.ToolErrors`).

  Every refusal is one of the codes `Autolaunch.AgentPayment.code/1` gives, or
  `invalid_request`, each with its own status and words for an agent here.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.AgentPayment.Refused
  alias AutolaunchWeb.{ApiError, ReadFailure}

  @refusals %{
    invalid_request:
      {:unprocessable_entity,
       "Send the token's id as autolaunch_tokens lists it, and in the body kind as pay or sweep, asset as usdc, regent or token, amount for pay only, and signer if you like, each as text."},
    authentication_required:
      {:unauthorized, "Your person's Regent account could not be read; nothing was prepared."},
    wrong_signer: {:forbidden, "That wallet is not one of your person's own wallets."},
    wallet_required:
      {:conflict,
       "Your person's Regent account has no verified wallet to act with, or signer is not a wallet address."},
    token_not_found: {:not_found, "There is no token listed here with that id."},
    invalid_amount:
      {:unprocessable_entity,
       "Send amount as a decimal above zero with no more decimal places than the asset has."},
    payment_not_offered: {:conflict, "This token does not take payments on this site."},
    payment_not_open:
      {:conflict,
       "Payments are not open on this token yet: it has no revenue split, treasury or payment address yet."},
    split_mismatch:
      {:conflict,
       "This token's revenue split or payment address is not the launch's own, so nothing was prepared."},
    amount_above_balance: {:conflict, "This wallet holds less than that."},
    nothing_to_sweep:
      {:conflict, "There is nothing of that asset waiting at the payment address right now."},
    chain_unavailable:
      {:service_unavailable, "Base could not be read just now. Try again in a moment."},
    payment_unavailable:
      {:service_unavailable, "That did not go through. Try again in a moment."}
  }

  @fields ~w(kind asset amount signer)

  @doc "Answers with the operation's answer, or with the refusal it carries."
  def send(conn, {:ok, answer}), do: json(conn, %{data: answer})
  def send(conn, {:error, error}), do: refuse(conn, reason(error))

  @doc "Answers with the refusal named `reason`."
  def refuse(conn, reason) do
    {status, code, message} = refusal(reason)
    ApiError.send(conn, status, code, message)
  end

  @doc "The error document of the refusal named `reason`, as the route sends it."
  def body(reason) do
    {_status, code, message} = refusal(reason)
    ApiError.body(code, message)
  end

  @doc """
  A route's body as the operation's input, or `:error` when it names a field
  the operation does not take or gives one as anything but text.
  """
  def input(body) do
    if Enum.all?(body, fn {key, value} -> key in @fields and is_binary(value) end),
      do: {:ok, body},
      else: :error
  end

  # The refusal the operation answered with: the code it named, or
  # `:invalid_request` for input the action itself does not take, such as a
  # token id that is not one, a kind or asset it does not offer, a payment
  # with no amount, a sweep with one, or a field longer than any it reads. A
  # policy does not refuse here: every caller of the route is a paired agent,
  # the route is not there while agent payments are off
  # (`AutolaunchWeb.Router.admit_offered/2`), and it is refused before the
  # router in prelaunch read-only mode (`AutolaunchWeb.Prelaunch`). Anything
  # else is logged by kind alone and answered `payment_unavailable`.
  defp reason(%Ash.Error.Unknown{errors: [%Refused{reason: reason}]}), do: reason
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request

  defp reason(unexpected) do
    ReadFailure.log("agent payment", unexpected)
    :payment_unavailable
  end

  defp refusal(reason) do
    {status, message} = Map.fetch!(@refusals, reason)
    {status, Atom.to_string(reason), message}
  end
end
