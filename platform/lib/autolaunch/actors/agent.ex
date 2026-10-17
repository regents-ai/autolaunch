defmodule Autolaunch.Actors.Agent do
  @moduledoc "A signed agent acting for the shared Regent account its pairing names."
  @enforce_keys [:wallet_address, :privy_user_id, :pairing_id, :human_account_id]
  defstruct [
    :wallet_address,
    :privy_user_id,
    :pairing_id,
    :human_account_id,
    :acting_agent_id,
    role: :agent
  ]
end
