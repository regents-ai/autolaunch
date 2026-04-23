defmodule Autolaunch.Revenue.Actions do
  @moduledoc false

  alias Autolaunch.Revenue.Core

  defdelegate stake(subject_id, attrs, current_human), to: Core
  defdelegate unstake(subject_id, attrs, current_human), to: Core
  defdelegate claim_usdc(subject_id, attrs, current_human), to: Core
  defdelegate claim_emissions(subject_id, attrs, current_human), to: Core
  defdelegate claim_and_stake_emissions(subject_id, attrs, current_human), to: Core
  defdelegate sweep_ingress(subject_id, ingress_address, attrs, current_human), to: Core
end
