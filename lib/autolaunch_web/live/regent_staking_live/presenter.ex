defmodule AutolaunchWeb.RegentStakingLive.Presenter do
  @moduledoc false

  def action_error(:unauthorized), do: "Connect a wallet first."
  def action_error(:operator_required), do: "Use an authorized operator wallet."
  def action_error(:unconfigured), do: "Regent staking is not configured here yet."
  def action_error(:amount_required), do: "Enter an amount first."
  def action_error(:invalid_amount_precision), do: "Amount precision is too high."
  def action_error(:invalid_address), do: "Address is invalid."
  def action_error(:invalid_ens_name), do: "ENS name is invalid."
  def action_error(:ens_address_missing), do: "ENS name does not point to a wallet."
  def action_error(:ens_unconfigured), do: "ENS lookup is unavailable right now."
  def action_error(:ens_unavailable), do: "ENS lookup could not be completed."
  def action_error(:source_tag_required), do: "Source label is required."
  def action_error(:source_ref_required), do: "Source reference is required."
  def action_error(:invalid_source_ref), do: "Source label or reference is invalid."
  def action_error(_reason), do: "Staking action could not be prepared."

  def chain_label(nil), do: "Not configured"
  def chain_label(%{chain_label: label}) when is_binary(label), do: label
  def chain_label(_state), do: "Base"
end
