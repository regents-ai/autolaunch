defmodule Autolaunch.Actors.Agent do
  @moduledoc "A signed agent with canonical shared identity and separate local product ownership."
  @enforce_keys [
    :wallet_address,
    :privy_user_id,
    :pairing_id,
    :human_account_id,
    :local_human_account_id
  ]
  defstruct [
    :wallet_address,
    :privy_user_id,
    :pairing_id,
    :human_account_id,
    :local_human_account_id,
    :acting_agent_id,
    role: :agent
  ]
end
