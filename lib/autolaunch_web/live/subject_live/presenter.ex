defmodule AutolaunchWeb.SubjectLive.Presenter do
  @moduledoc false

  alias AutolaunchWeb.Format

  @side_tabs ~w(state balances addresses)

  def wallet_position(subject) do
    staked = subject_value(subject, :wallet_stake_balance)
    wallet = subject_value(subject, :wallet_token_balance)
    claimable_usdc = subject_value(subject, :claimable_usdc)
    claimable_emissions = subject_value(subject, :claimable_stake_token)

    %{
      wallet_stake_balance: staked,
      wallet_token_balance: wallet,
      claimable_usdc: claimable_usdc,
      claimable_stake_token: claimable_emissions,
      summary:
        "Your staked agent-token balance, wallet balance, claimable USDC, and claimable agent-token emissions all live here.",
      staked_line: "Staked agent tokens: #{staked}",
      wallet_line: "Wallet agent tokens: #{wallet}",
      claimable_usdc_line: "USDC: #{claimable_usdc}",
      claimable_emissions_line: "Agent-token emissions: #{claimable_emissions}",
      stake_note: "Wallet agent-token balance: #{wallet}.",
      unstake_note: "Currently staked agent tokens: #{staked}.",
      claim_note: "Claimable now: #{claimable_usdc}.",
      emissions_note: "Claimable agent-token emissions: #{claimable_emissions}."
    }
  end

  def recommended_action(nil), do: nil

  def recommended_action(subject) do
    cond do
      positive_amount?(Map.get(subject, :claimable_usdc)) -> :claim
      positive_amount?(Map.get(subject, :wallet_token_balance)) -> :stake
      positive_amount?(Map.get(subject, :wallet_stake_balance)) -> :unstake
      true -> nil
    end
  end

  def recommended_action_heading(:claim), do: "Claim available USDC first"
  def recommended_action_heading(:stake), do: "Stake idle wallet balance next"
  def recommended_action_heading(:unstake), do: "Unstake if you need wallet liquidity"

  def recommended_action_heading(_), do: "No urgent wallet action detected"

  def recommended_action_summary(:claim, wallet_position) do
    "The wallet already has #{wallet_position.claimable_usdc} USDC ready. Pull that out before moving on to the rest of the subject actions."
  end

  def recommended_action_summary(:stake, wallet_position) do
    "This wallet still holds #{wallet_position.wallet_token_balance} unstaked agent tokens. Move the amount you want into the subject revenue contract so future subject revenue stays attached to the position."
  end

  def recommended_action_summary(:unstake, wallet_position) do
    "There is no claimable USDC or idle wallet balance, but #{wallet_position.wallet_stake_balance} agent tokens are still committed. Unstake only if you want that balance back in the wallet."
  end

  def recommended_action_summary(_, _wallet_position) do
    "Everything important is in view. Use the action cards below when you need to claim, stake, sweep, or inspect the contract details."
  end

  def recommended_status_label(:claim), do: "Claim ready"
  def recommended_status_label(:stake), do: "Stake ready"
  def recommended_status_label(:unstake), do: "Unstake available"
  def recommended_status_label(_), do: "Active"

  def subject_heading(_subject, _subject_id, %{agent_name: agent_name})
      when is_binary(agent_name) and agent_name != "" do
    agent_name
  end

  def subject_heading(subject, subject_id, _subject_market) when is_map(subject) do
    "Subject #{String.slice(subject.subject_id || subject_id, 0, 10)}"
  end

  def subject_heading(_subject, subject_id, _subject_market) do
    "Subject #{String.slice(subject_id, 0, 10)}"
  end

  def subject_summary(_subject, %{phase: "live"}) do
    "Use this page for the next wallet action: claim, stake, unstake, or move revenue out after the market has settled."
  end

  def subject_summary(_subject, %{phase: "biddable"}) do
    "This token is still in market. Use the auction page for price discovery and this page for the balances that follow."
  end

  def subject_summary(subject, _subject_market) when is_map(subject) do
    "Use this page for the next wallet action: claim, stake, unstake, or move revenue out when the balance is ready."
  end

  def subject_summary(_subject, _subject_market) do
    "Review what this wallet can claim, what is already committed, and which intake balances still need attention."
  end

  def subject_symbol(%{symbol: symbol}) when is_binary(symbol) and symbol != "", do: symbol
  def subject_symbol(_subject_market), do: nil

  def subject_auction_href(%{id: id}) when is_binary(id), do: "/auctions/#{id}"
  def subject_auction_href(_subject_market), do: nil

  def subject_initials(heading) when is_binary(heading) do
    heading
    |> String.replace("Subject ", "")
    |> String.slice(0, 2)
    |> String.upcase()
  end

  def side_tab_label("state"), do: "Subject state"
  def side_tab_label("balances"), do: "Balances"
  def side_tab_label("addresses"), do: "Addresses"
  def side_tabs, do: @side_tabs

  def action_to_atom("stake"), do: {:ok, :stake}
  def action_to_atom("unstake"), do: {:ok, :unstake}
  def action_to_atom("claim"), do: {:ok, :claim}
  def action_to_atom(_action), do: :error

  def action_error(:unauthorized), do: "Privy session required before this wallet action."
  def action_error(:forbidden), do: "This wallet cannot perform that subject action."

  def action_error(:amount_required),
    do: "Enter an amount before preparing the wallet transaction."

  def action_error(:invalid_address), do: "Wallet address is invalid."

  def action_error(_reason), do: "Unable to prepare the wallet transaction right now."

  def routing_snapshot(nil) do
    %{
      live_share: "100%",
      pending_share: "No pending change",
      pending_note: "No delayed share update is queued right now.",
      activation_date: "Not scheduled",
      cooldown_end: "Ready now",
      total_received: "0",
      verified_revenue: "0",
      regent_skim: "0",
      staker_eligible_inflow: "0",
      treasury_reserved_inflow: "0",
      treasury_reserved_balance: "0",
      treasury_residual: "0",
      history_count: "0 recorded changes",
      change_chart: nil
    }
  end

  def routing_snapshot(subject) do
    history_count = length(Map.get(subject, :share_change_history, []))
    pending_share = Map.get(subject, :pending_eligible_revenue_share_percent)

    %{
      live_share: percent_value(Map.get(subject, :eligible_revenue_share_percent, "100")),
      pending_share:
        if(pending_share, do: percent_value(pending_share), else: "No pending change"),
      pending_note:
        if(pending_share,
          do: "This delayed update is waiting for its activation window.",
          else: "No delayed share update is queued right now."
        ),
      activation_date:
        Format.display_datetime(Map.get(subject, :pending_eligible_revenue_share_eta)) ||
          "Not scheduled",
      cooldown_end:
        Format.display_datetime(Map.get(subject, :eligible_revenue_share_cooldown_end)) ||
          "Ready now",
      total_received: money_value(Map.get(subject, :total_usdc_received)),
      verified_revenue: money_value(Map.get(subject, :verified_ingress_usdc)),
      regent_skim: money_value(Map.get(subject, :regent_skim_usdc)),
      staker_eligible_inflow: money_value(Map.get(subject, :staker_eligible_inflow_usdc)),
      treasury_reserved_inflow: money_value(Map.get(subject, :treasury_reserved_inflow_usdc)),
      treasury_reserved_balance: money_value(Map.get(subject, :treasury_reserved_usdc)),
      treasury_residual: money_value(Map.get(subject, :treasury_residual_usdc)),
      history_count:
        if(history_count == 1, do: "1 recorded change", else: "#{history_count} recorded changes"),
      change_chart: rate_change_chart(subject)
    }
  end

  def history_label(%{type: "proposed"}), do: "Queued"
  def history_label(%{type: "cancelled"}), do: "Cancelled"
  def history_label(%{type: "activated"}), do: "Live"
  def history_label(_entry), do: "Update"

  def history_primary_value(%{type: "proposed", pending_share_percent: percent}),
    do: percent_value(percent)

  def history_primary_value(%{type: "cancelled", cancelled_share_percent: percent}),
    do: percent_value(percent)

  def history_primary_value(%{type: "activated", new_share_percent: percent}),
    do: percent_value(percent)

  def history_primary_value(_entry), do: "Recorded"

  def history_copy(%{
        type: "proposed",
        current_share_percent: current,
        pending_share_percent: pending,
        activation_eta: eta
      }) do
    "A delayed change from #{percent_value(current)} to #{percent_value(pending)} was queued. It can first go live on #{Format.display_datetime(eta) || "the recorded activation date"}."
  end

  def history_copy(%{
        type: "cancelled",
        cancelled_share_percent: percent,
        cooldown_end: cooldown_end
      }) do
    "The pending #{percent_value(percent)} change was cleared. A fresh proposal can be queued after #{Format.display_datetime(cooldown_end) || "the recorded cooldown date"}."
  end

  def history_copy(%{
        type: "activated",
        previous_share_percent: previous,
        new_share_percent: new_share,
        cooldown_end: cooldown_end
      }) do
    "The live share moved from #{percent_value(previous)} to #{percent_value(new_share)}. Another proposal can be queued after #{Format.display_datetime(cooldown_end) || "the recorded cooldown date"}."
  end

  def history_copy(_entry), do: "This share change was recorded onchain."

  def history_timestamp(%{happened_at: happened_at}) do
    Format.display_datetime(happened_at) || "Time unavailable"
  end

  def public_revenue_proof_rows(subject) when is_map(subject) do
    proof = Map.get(subject, :recognized_revenue_proof) || %{}

    [
      %{id: "source", label: "Source", value: proof_value(proof, :source)},
      %{id: "chain", label: "Chain", value: proof_value(proof, :chain_id)},
      %{id: "ingress", label: "Ingress account", value: proof_address(proof, :ingress)},
      %{id: "revsplit", label: "Revsplit contract", value: proof_address(proof, :revsplit)},
      %{id: "block", label: "Block number", value: proof_value(proof, :block_number)},
      %{id: "amount", label: "Amount", value: proof_amount(proof)},
      %{
        id: "recipient-lane",
        label: "Recipient lane",
        value: proof_value(proof, :recipient_lane)
      },
      %{id: "status", label: "Freshness", value: proof_value(proof, :status)}
    ]
  end

  def public_revenue_proof_rows(_subject), do: []

  defp subject_value(nil, _key), do: "0"
  defp subject_value(subject, key) when is_map(subject), do: Map.get(subject, key, "0")

  defp proof_value(proof, key) do
    case Map.get(proof, key) do
      nil -> "Unavailable"
      "" -> "Unavailable"
      value -> to_string(value)
    end
  end

  defp proof_address(proof, key) do
    case proof_value(proof, key) do
      "Unavailable" -> "Unavailable"
      value -> Format.short_address(value, value)
    end
  end

  defp proof_amount(proof) do
    case proof_value(proof, :amount) do
      "Unavailable" -> "Unavailable"
      amount -> "#{amount} USDC"
    end
  end

  defp positive_amount?(nil), do: false

  defp positive_amount?(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.compare(decimal, Decimal.new(0)) == :gt
      _ -> false
    end
  end

  defp positive_amount?(_value), do: false

  defp rate_change_chart(subject) do
    current_bps = Map.get(subject, :eligible_revenue_share_bps, 10_000)
    pending_bps = Map.get(subject, :pending_eligible_revenue_share_bps)

    if is_integer(pending_bps) and pending_bps > 0 do
      current_x = 36
      next_x = 204
      current_y = share_chart_y(current_bps)
      next_y = share_chart_y(pending_bps)

      %{
        current_date: Format.display_chart_date(DateTime.utc_now()),
        current_rate: percent_value(Map.get(subject, :eligible_revenue_share_percent, "100")),
        next_date:
          Format.display_chart_date(Map.get(subject, :pending_eligible_revenue_share_eta)),
        next_rate: percent_value(Map.get(subject, :pending_eligible_revenue_share_percent)),
        headline:
          "This share is scheduled to move from #{format_bps_percent(current_bps)} to #{format_bps_percent(pending_bps)}.",
        summary:
          "Today the live share is #{format_bps_percent(current_bps)}. On #{Format.display_chart_date(Map.get(subject, :pending_eligible_revenue_share_eta))}, it is scheduled to change to #{format_bps_percent(pending_bps)}.",
        current_x: current_x,
        current_y: current_y,
        next_x: next_x,
        next_y: next_y,
        current_label_y: max(current_y - 12, 18),
        next_label_y: max(next_y - 12, 18),
        line_points: "#{current_x},#{current_y} #{next_x},#{next_y}"
      }
    end
  end

  defp money_value(nil), do: "0 USDC"
  defp money_value(value), do: "#{value} USDC"

  defp percent_value(nil), do: "n/a"
  defp percent_value(value), do: "#{value}%"

  defp format_bps_percent(value) when is_integer(value) do
    value
    |> Kernel./(100)
    |> :erlang.float_to_binary(decimals: 2)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> percent_value()
  end

  defp share_chart_y(bps) when is_integer(bps) do
    min_y = 24
    max_y = 92
    inverted_share = 10_000 - bps
    min_y + round(inverted_share * (max_y - min_y) / 10_000)
  end
end
