defmodule AutolaunchWeb.AgentPress do
  @moduledoc """
  An agent's press on a wallet card, from the page tools in
  `assets/js/agent_wallet_tools.ts`. The card prepares exactly what its own
  button would send and hands it to the browser with `send` and `agent`, so the
  browser opens the wallet at once and answers the call with the wallet's
  reply. When the card cannot prepare anything, `refused/3` answers the call
  with the card's own words.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  @doc "The browser's review payload, sending `step` at once for the agent's `call`."
  def sending(payload, step, call, remaining),
    do: Map.merge(payload, %{send: step, agent: %{call: call, remaining: remaining}})

  @doc "Answers the agent's call with why nothing was sent."
  def refused(socket, call, message),
    do:
      push_event(socket, "agent-tools:refused", %{
        component_id: socket.assigns.id,
        call: call,
        message: message
      })

  @doc "The labels of the steps after `step`, in order."
  def remaining(steps, step, label) do
    steps
    |> Enum.map(& &1["step"])
    |> Enum.drop_while(&(&1 != step))
    |> Enum.drop(1)
    |> Enum.map(label)
  end
end
