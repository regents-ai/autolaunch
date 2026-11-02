defmodule Autolaunch.Points.Launch do
  @moduledoc """
  Regent Points' check of a launch: it reads the saved auction and answers with
  what Points records for the account whose review carried the launch out. A
  listed auction counts for `autolaunch.auction_created` and
  `autolaunch.first_launch`; a graduated one for `autolaunch.first_graduation`,
  at the time its token was recorded. An auction the site has taken off its
  lists earns nothing.
  """

  alias Autolaunch.Actors.System

  def verify(%{"source_kind" => "auction", "source_event_key" => id}) do
    with {:ok, auction} <- auction(id),
         do: {:ok, facts(auction, "auction", auction.inserted_at)}
  end

  def verify(%{"source_kind" => "graduation", "source_event_key" => id}) do
    with {:ok, %{state: :graduated} = auction} <- auction(id),
         {:ok, %{graduated_at: %DateTime{} = at}} <- token(id) do
      {:ok, facts(auction, "graduation", at)}
    else
      {:ok, %{state: _not_graduated}} -> {:error, :auction_not_graduated}
      # The token is recorded just after the auction is seen to graduate.
      {:ok, nil} -> {:retry, :token_not_recorded}
      {:error, _reason} = error -> error
      {:retry, _reason} = retry -> retry
    end
  end

  defp auction(id) do
    case Autolaunch.get_listed_auction(id, actor: %System{}) do
      {:ok, %{creator_human_account_id: account_id} = auction} when is_integer(account_id) ->
        {:ok, auction}

      {:ok, nil} ->
        {:error, :auction_not_found}

      {:ok, _chain_only} ->
        {:error, :auction_without_creator}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp token(auction_id) do
    case Autolaunch.get_token_for_projection(auction_id, actor: %System{}) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp facts(auction, kind, at) do
    %{
      source_app: "autolaunch",
      source_kind: kind,
      source_event_key: auction.id,
      account_id: auction.creator_human_account_id,
      actor_kind: "human",
      actor_id: to_string(auction.creator_human_account_id),
      source_action_at: at,
      qualified_at: at,
      evidence_ref: kind <> ":" <> auction.id,
      evidence: %{"chain_id" => auction.chain_id, "auction_address" => auction.auction_address}
    }
  end
end
