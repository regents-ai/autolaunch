defmodule AutolaunchWeb.AgentFinishAnswer do
  @moduledoc """
  The agent finish answers the HTTP route gives
  (`AutolaunchWeb.AgentFinishController`): the answer the operation built
  (`Autolaunch.AgentFinish`) as `data`, or its refusal with its status and
  words. The hosted MCP tool gives the same refusals in the same words
  (`body/1`, through `AutolaunchWeb.ToolErrors`).

  Every refusal is an `Autolaunch.AgentFinish.Refused` holding one of the codes
  `Autolaunch.AgentFinish.code/1` gives, each with its own status and words for
  an agent here; a finish not open yet names the block it opens at.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.AgentFinish.Refused
  alias AutolaunchWeb.{ApiError, ReadFailure}

  @refusals %{
    invalid_request:
      {:unprocessable_entity,
       "Send the auction's id as autolaunch_auctions lists it, and only signer in the body, as text."},
    authentication_required:
      {:unauthorized, "Your person's Regent account could not be read; nothing was prepared."},
    wrong_signer: {:forbidden, "That wallet is not one of your person's own wallets."},
    wallet_required:
      {:conflict,
       "Your person's Regent account has no verified wallet to act with, or signer is not a wallet address."},
    auction_not_found: {:not_found, "There is no auction listed here with that id."},
    auction_finished:
      {:conflict, "This auction is already finished, so the launchpad would refuse this."},
    chain_unavailable:
      {:service_unavailable,
       "The auction's chain could not be read just now. Try again in a moment."},
    finish_unavailable: {:service_unavailable, "That did not go through. Try again in a moment."}
  }

  @fields ~w(signer)

  @doc "Answers with the operation's answer, or with the refusal it carries."
  def send(conn, {:ok, answer}), do: json(conn, %{data: answer})
  def send(conn, {:error, error}), do: refuse(conn, refused(error))

  @doc "Answers with `refused`, an `Autolaunch.AgentFinish.Refused`."
  def refuse(conn, %Refused{} = refused) do
    {status, code, message} = refusal(refused)
    ApiError.send(conn, status, code, message)
  end

  @doc "The error document of `refused`, as the route sends it."
  def body(%Refused{} = refused) do
    {_status, code, message} = refusal(refused)
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

  # The refusal the operation answered with, or `invalid_request` for input the
  # action itself does not take, such as an auction id that is not one. A
  # policy does not refuse here: every caller of the route is a paired agent,
  # the route is not there while agent finishes are off
  # (`AutolaunchWeb.Router.admit_agent_finish/2`), and it is refused before the
  # router in prelaunch read-only mode (`AutolaunchWeb.Prelaunch`). Anything
  # else is logged by kind alone and answered `finish_unavailable`.
  defp refused(%Ash.Error.Unknown{errors: [%Refused{} = refused]}), do: refused
  defp refused(%Ash.Error.Invalid{}), do: Refused.exception(reason: :invalid_request)

  defp refused(unexpected) do
    ReadFailure.log("agent finish", unexpected)
    Refused.exception(reason: :finish_unavailable)
  end

  defp refusal(%Refused{reason: :finish_not_open, opens_at: opens_at}),
    do:
      {:conflict, "finish_not_open",
       "Finishing this auction opens at block #{opens_at}; the launchpad refuses it before then."}

  defp refusal(%Refused{reason: reason}) do
    {status, message} = Map.fetch!(@refusals, reason)
    {status, Atom.to_string(reason), message}
  end
end
