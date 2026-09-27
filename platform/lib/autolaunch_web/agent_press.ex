defmodule AutolaunchWeb.AgentPress do
  @moduledoc """
  An agent's press on a wallet card, from the page tools in
  `assets/js/agent_wallet_tools.ts`. The card answers `agent_press` with the
  review its own button would send from and the step to send, and the browser
  opens the wallet at once; or, when the card cannot prepare anything, with its
  own words for why.
  """

  @doc """
  The reply that sends `step` of `review` for the agent, naming the steps still
  to send after it with `label`.
  """
  def sending(%{steps: steps} = review, step, label) do
    remaining =
      steps
      |> Enum.map(& &1.step)
      |> Enum.drop_while(&(&1 != step))
      |> Enum.drop(1)
      |> Enum.map(label)

    %{review: review, send: step, remaining: remaining}
  end

  @doc "The reply for a call the card could not prepare anything for."
  def refused(message), do: %{message: message}
end
