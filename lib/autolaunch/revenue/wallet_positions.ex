defmodule Autolaunch.Revenue.WalletPositions do
  @moduledoc false

  alias Autolaunch.Revenue.Core

  defdelegate subject_wallet_position(subject_id, wallet_address), to: Core
  defdelegate subject_wallet_positions(subject_id, wallet_addresses), to: Core
  defdelegate subject_obligation_metrics(subject_id, staker_addresses), to: Core
end
