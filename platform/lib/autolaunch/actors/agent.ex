defmodule Autolaunch.Actors.Agent do
  @moduledoc """
  A signed agent acting for the shared Regent account its pairing names.

  `connection` is set when the agent is a connected app's own identity, acting
  through the hosted MCP server with the token its person approved: what
  `RegentOAuth.verify/3` answered for that token. The same app may then also run
  its identity tools (`Autolaunch.Agents.Connection`).
  """
  @enforce_keys [:wallet_address, :privy_user_id, :pairing_id, :human_account_id]
  defstruct [
    :wallet_address,
    :privy_user_id,
    :pairing_id,
    :human_account_id,
    :acting_agent_id,
    :connection,
    role: :agent
  ]

  @type t :: %__MODULE__{}
end
