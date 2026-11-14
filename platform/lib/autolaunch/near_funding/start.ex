defmodule Autolaunch.NearFunding.Start do
  @moduledoc """
  Starts a funding: before the write, asks the 1Click service for a quote with
  a deposit address for the acting account's own wallet; with the write, queues
  the funding's status job (`Autolaunch.NearFunding.Watch`).
  """
  use Ash.Resource.Change

  alias Autolaunch.NearFunding.{Intents, Watch}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_transaction(&quoted(&1, context.actor))
    |> Ash.Changeset.after_action(fn _changeset, funding ->
      with {:ok, _job} <- Oban.insert(Watch.new(%{id: funding.id})), do: {:ok, funding}
    end)
  end

  defp quoted(changeset, actor) do
    %{auction_id: auction_id, usdc_amount: usdc_amount, refund_to: refund_to} =
      changeset.arguments

    case Intents.quote(actor, auction_id, usdc_amount, refund_to, false) do
      {:ok, terms} ->
        Ash.Changeset.force_change_attributes(
          changeset,
          Map.merge(terms, %{
            human_account_id: actor.human_account_id,
            auction_id: auction_id,
            refund_to: refund_to
          })
        )

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Unknown.UnknownError.exception(error: reason)
        )
    end
  end
end
