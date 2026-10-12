defmodule Autolaunch.Credits.Credited do
  @moduledoc """
  When a Credits purchase is credited, asks Regent Points to consider it, inside
  the credit's transaction. Points decides whether the purchase earns; while its
  rule is off nothing is queued.
  """

  @behaviour RegentCredits.Credited

  alias Autolaunch.Actors.System

  @impl true
  def credited(purchase) do
    reference = %{
      rule_id: "credits.purchase_settled",
      # Credits is one Regents ledger, so every site names it "regents" and a purchase earns once.
      source_app: "regents",
      source_kind: "credits_purchase",
      source_event_key: purchase.id
    }

    {:ok, _} = RegentPoints.record_event(reference, actor: %System{})
    :ok
  end
end
