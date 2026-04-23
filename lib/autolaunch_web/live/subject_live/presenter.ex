defmodule AutolaunchWeb.SubjectLive.Presenter do
  @moduledoc false

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
        "Your staked balance, wallet balance, claimable USDC, and claimable emissions all live here.",
      staked_line: "Staked: #{staked}",
      wallet_line: "Wallet: #{wallet}",
      claimable_usdc_line: "USDC: #{claimable_usdc}",
      claimable_emissions_line: "Emissions: #{claimable_emissions}",
      stake_note: "Wallet balance: #{wallet}.",
      unstake_note: "Currently staked: #{staked}.",
      claim_note: "Claimable now: #{claimable_usdc}.",
      emissions_note: "Claimable emissions: #{claimable_emissions}."
    }
  end

  def recommended_action(nil), do: nil

  def recommended_action(subject) do
    cond do
      positive_amount?(Map.get(subject, :claimable_usdc)) -> :claim
      positive_amount?(Map.get(subject, :wallet_token_balance)) -> :stake
      positive_amount?(Map.get(subject, :wallet_stake_balance)) -> :unstake
      positive_amount?(Map.get(subject, :claimable_stake_token)) -> :claim_and_stake_emissions
      true -> nil
    end
  end

  def recommended_action_heading(:claim), do: "Claim recognized USDC first"
  def recommended_action_heading(:stake), do: "Stake idle wallet balance next"
  def recommended_action_heading(:unstake), do: "Unstake if you need wallet liquidity"

  def recommended_action_heading(:claim_and_stake_emissions),
    do: "Roll emissions back into stake"

  def recommended_action_heading(_), do: "No urgent wallet action detected"

  def recommended_action_summary(:claim, wallet_position) do
    "The wallet already has #{wallet_position.claimable_usdc} USDC ready. Pull that out before moving on to the rest of the subject actions."
  end

  def recommended_action_summary(:stake, wallet_position) do
    "This wallet still holds #{wallet_position.wallet_token_balance} unstaked tokens. Move the amount you want into the splitter so revenue stays attached to the position."
  end

  def recommended_action_summary(:unstake, wallet_position) do
    "There is no claimable USDC or idle wallet balance, but #{wallet_position.wallet_stake_balance} tokens are still committed. Unstake only if you want that balance back in the wallet."
  end

  def recommended_action_summary(:claim_and_stake_emissions, _wallet_position) do
    "Reward emissions are available now. Claim them on their own or move them straight back into the splitter."
  end

  def recommended_action_summary(_, _wallet_position) do
    "Everything important is in view. Use the action cards below when you need to claim, stake, sweep, or inspect the contract details."
  end

  def recommended_status_label(:claim), do: "Claim ready"
  def recommended_status_label(:stake), do: "Stake ready"
  def recommended_status_label(:unstake), do: "Unstake available"
  def recommended_status_label(:claim_and_stake_emissions), do: "Emissions ready"
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

  defp subject_value(nil, _key), do: "0"
  defp subject_value(subject, key) when is_map(subject), do: Map.get(subject, key, "0")

  defp positive_amount?(nil), do: false

  defp positive_amount?(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.compare(decimal, Decimal.new(0)) == :gt
      _ -> false
    end
  end

  defp positive_amount?(_value), do: false
end
