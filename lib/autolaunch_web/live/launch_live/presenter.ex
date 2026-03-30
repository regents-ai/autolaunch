defmodule AutolaunchWeb.LaunchLive.Presenter do
  @moduledoc false

  def regent_step_title(1), do: "Choose an eligible agent"
  def regent_step_title(2), do: "Set launch terms"
  def regent_step_title(3), do: "Review and sign"
  def regent_step_title(4), do: "Queue and monitor"
  def regent_step_title(5), do: "Deployment status"
  def regent_step_title(_step), do: "Launch control"

  def regent_step_summary(1, _selected_agent, _current_job),
    do:
      "Pick the ERC-8004 identity that is actually allowed to launch. The spatial surface is only there to orient you; the review cards still hold the real evidence."

  def regent_step_summary(2, selected_agent, _current_job),
    do:
      "Set token routing and recovery details for #{(selected_agent && (selected_agent.name || selected_agent.agent_id)) || "the chosen agent"} before asking for any signature."

  def regent_step_summary(3, _selected_agent, _current_job),
    do:
      "This is the irreversible checkpoint. Review the fixed supply, treasury routing, and the optional trust check before you sign."

  def regent_step_summary(4, _selected_agent, current_job),
    do:
      "The job is queued. Keep the browser on live queue state while the CLI remains the cleaner operator path. Current state: #{regent_job_status(current_job)}."

  def regent_step_summary(5, _selected_agent, current_job),
    do:
      "The launch stack is now in deployment tracking. Current state: #{regent_job_status(current_job)}."

  def regent_step_summary(_step, _selected_agent, _current_job),
    do: "Launch control is live."

  def regent_job_status(nil), do: "Awaiting queue"
  def regent_job_status(%{job: %{status: status}}), do: String.replace(status, "_", " ")

  def short_address(nil), do: "pending"

  def short_address(address) when is_binary(address) do
    address
    |> String.downcase()
    |> then(fn value ->
      if String.length(value) > 12 do
        String.slice(value, 0, 6) <> "..." <> String.slice(value, -4, 4)
      else
        value
      end
    end)
  end

  def access_mode_label("owner"), do: "Owner"
  def access_mode_label("operator"), do: "Operator"
  def access_mode_label("wallet_bound"), do: "Wallet-bound"
  def access_mode_label(_mode), do: "Unknown"

  def disabled_agent_message(%{state: "already_launched"}),
    do: "This ERC-8004 identity already has an Agent Coin."

  def disabled_agent_message(%{access_mode: "wallet_bound"}),
    do:
      "This identity is only wallet-bound. Launching requires ERC-8004 owner or operator access."

  def disabled_agent_message(_agent),
    do: "Finish the missing setup before launch."

  def reputation_action_status("complete"), do: "Complete"
  def reputation_action_status("available"), do: "Ready now"
  def reputation_action_status("pending"), do: "Available after launch"
  def reputation_action_status(_status), do: "Optional"
end
