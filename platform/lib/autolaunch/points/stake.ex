defmodule Autolaunch.Points.Stake do
  @moduledoc """
  Regent Points' check of a stake (`autolaunch.token_staked`): it reads the
  saved stake row and the token, as the public lists carry it, and answers
  with what Points records for the account whose linked wallet staked.

  Each `Staked` log of a launch's splitter is saved once by the token's
  reader (`Autolaunch.TokenTrades`), and neither reading it again nor a
  rebuild of the token's trades removes or changes it. The staker is the
  wallet the log names, the one that called `stake`. A stake happened at its
  block's time, and the account that earns is the one whose verified wallets
  held the staking wallet at that moment (`RegentPoints.WalletSnapshot.owner/2`).
  Unstaking is not recorded and takes nothing back. A stake of a token an
  operator hid or the lists leave out earns nothing, and neither does one
  whose wallet no single account held then.

  A stake is offered only when it is first saved, so one saved while this
  rule is not approved is never offered later. A stake the chain later took
  back stays saved, and keeps anything it earned.
  """

  alias Autolaunch.Actors.System
  alias RegentPoints.WalletSnapshot

  def verify(%{"source_event_key" => id}) do
    with {:ok, stake} <-
           saved(Autolaunch.get_token_stake(id, actor: %System{}), :stake_not_found),
         {:ok, _token} <-
           saved(
             Autolaunch.get_listed_token(stake.token_id, actor: %System{}),
             :stake_not_listed
           ),
         {:ok, account_id} <- staker(stake) do
      {:ok, facts(stake, account_id)}
    end
  end

  # A row the read does not find refuses for good; a read that failed is
  # asked again.
  defp saved({:ok, nil}, refusal), do: {:error, refusal}
  defp saved({:ok, record}, _refusal), do: {:ok, record}
  defp saved({:error, reason}, _refusal), do: {:retry, reason}

  defp staker(stake) do
    case WalletSnapshot.owner(stake.staker, stake.occurred_at) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, :unknown_owner} -> {:error, :staker_wallet_not_linked}
    end
  end

  defp facts(stake, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "stake",
      source_event_key: stake.id,
      account_id: account_id,
      # The staking wallet is the account's own; nothing saved names an agent.
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: stake.occurred_at,
      qualified_at: stake.occurred_at,
      evidence_ref: "stake:" <> stake.id,
      evidence: %{
        "token_id" => stake.token_id,
        "chain_id" => stake.chain_id,
        "splitter" => stake.splitter,
        "staker" => stake.staker,
        "amount" => Decimal.to_string(stake.amount),
        "transaction_hash" => stake.transaction_hash,
        "log_index" => stake.log_index
      }
    }
  end
end
