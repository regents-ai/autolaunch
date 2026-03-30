defmodule AutolaunchWeb.LaunchLive.Flow do
  @moduledoc false

  @agent_launch_total_supply "100000000000000000000000000000"

  def default_form(nil) do
    %{
      "agent_id" => nil,
      "token_name" => "",
      "token_symbol" => "",
      "recovery_safe_address" => "",
      "auction_proceeds_recipient" => "",
      "ethereum_revenue_treasury" => "",
      "total_supply" => @agent_launch_total_supply,
      "launch_notes" => ""
    }
  end

  def default_form(current_human) do
    default_form(nil)
    |> Map.put("recovery_safe_address", current_human.wallet_address || "")
    |> Map.put("auction_proceeds_recipient", current_human.wallet_address || "")
    |> Map.put("ethereum_revenue_treasury", current_human.wallet_address || "")
  end

  def max_available_step(%{job_id: job_id, preview: preview, selected_agent: selected_agent}) do
    cond do
      job_id -> 5
      preview -> 3
      selected_agent -> 2
      true -> 1
    end
  end

  def normalize_step(step) when is_binary(step) do
    case Integer.parse(step) do
      {value, ""} -> value
      _ -> 1
    end
  end

  def normalize_step(step) when is_integer(step), do: step
  def normalize_step(_step), do: 1

  def preview_error(:token_name_required), do: "Token name is required."
  def preview_error(:token_symbol_required), do: "Token symbol is required."

  def preview_error(:invalid_wallet_address),
    do: "Each launch recipient must be a valid EVM address."

  def preview_error(:invalid_chain_id), do: "Launch network is not configured."
  def preview_error(:agent_not_found), do: "Select an eligible agent first."
  def preview_error(_reason), do: "Launch preview could not be prepared."

  def current_reputation_prompt(_preview, %{job: %{reputation_prompt: prompt}})
      when is_map(prompt),
      do: prompt

  def current_reputation_prompt(%{reputation_prompt: prompt}, _current_job) when is_map(prompt),
    do: prompt

  def current_reputation_prompt(_preview, _current_job), do: nil
end
