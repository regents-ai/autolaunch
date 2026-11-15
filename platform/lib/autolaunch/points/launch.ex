defmodule Autolaunch.Points.Launch do
  @moduledoc """
  Regent Points' check of a launch: it reads the launch's auction row, as the
  public lists carry it, and answers with what Points records for the account
  whose linked wallet sent the launch. It checks both `autolaunch.first_launch`
  and `autolaunch.auction_created`, since every launch opens its one auction.

  In the site's own data the launch happened when its row was saved. The
  account that earns is the one whose verified wallets held the launching
  wallet at that moment (`RegentPoints.WalletSnapshot.owner/2`), so linking,
  moving or removing the wallet later never changes who earned. A launch an
  operator hid, or one the lists leave out (a Robinhood launch made outside
  the site), earns nothing, and neither does one whose wallet no single
  account held then.
  """

  alias Autolaunch.Actors.System
  alias RegentPoints.WalletSnapshot

  def verify(%{"source_event_key" => id}) do
    case Autolaunch.get_listed_auction(id, actor: %System{}) do
      {:ok, %{} = auction} ->
        with {:ok, account_id} <- creator(auction), do: {:ok, facts(auction, account_id)}

      {:ok, nil} ->
        {:error, :launch_not_listed}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  @doc """
  The account whose verified wallets held the wallet that launched `auction`
  when the site saved the launch: `{:ok, account_id}`, or
  `{:error, :creator_wallet_not_linked}` when no account, or more than one,
  held it then.
  """
  def creator(auction) do
    case WalletSnapshot.owner(auction.creator_address, auction.inserted_at) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, :unknown_owner} -> {:error, :creator_wallet_not_linked}
    end
  end

  defp facts(auction, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "auction",
      source_event_key: auction.id,
      account_id: account_id,
      # The account itself signs every launch; an agent never does.
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: auction.inserted_at,
      qualified_at: auction.inserted_at,
      evidence_ref: "auction:" <> auction.id,
      evidence: %{"launcher" => auction.creator_address}
    }
  end
end
