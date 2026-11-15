defmodule Autolaunch.Points.Graduation do
  @moduledoc """
  Regent Points' check of a graduation (`autolaunch.first_graduation`): it
  reads the graduated token row, as the public lists carry it, and answers
  with what Points records for the launch's creator.

  The token row exists only once its auction graduated, and it keeps the time
  the site first saw it graduate (`graduated_at`), which is when the
  graduation happened in the site's own data. The creator is the account that
  launched it, found as `Autolaunch.Points.Launch.creator/1` finds it: the
  account whose verified wallets held the launching wallet when the site saved
  the launch. A token whose auction an operator hid, or one the lists leave
  out, earns nothing.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.Points.Launch

  def verify(%{"source_event_key" => id}) do
    case Autolaunch.get_listed_token(id, actor: %System{}) do
      {:ok, %{} = token} ->
        with {:ok, account_id} <- Launch.creator(token.auction),
             do: {:ok, facts(token, account_id)}

      {:ok, nil} ->
        {:error, :graduation_not_listed}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp facts(token, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "token",
      source_event_key: token.id,
      account_id: account_id,
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: token.graduated_at,
      qualified_at: token.graduated_at,
      evidence_ref: "token:" <> token.id,
      evidence: %{"auction_id" => token.auction_id, "launcher" => token.auction.creator_address}
    }
  end
end
