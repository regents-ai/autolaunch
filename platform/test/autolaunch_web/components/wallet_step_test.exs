defmodule AutolaunchWeb.Components.WalletStepTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.SwapForm

  @bid %{name: "bid", label: "Place bid", state: :ready}

  # A button that sends every step at once sends nothing while it is held:
  # neither the step on it nor the batch.
  test "a held button that would send every step at once sends neither its step nor the batch" do
    held = button(blocked: "Bidding has ended.")

    assert LazyHTML.attribute(held, "disabled") == [""]
    assert LazyHTML.attribute(held, "data-onchain-bundle") == []
    assert LazyHTML.attribute(held, "data-onchain-step") == []

    assert LazyHTML.attribute(button(blocked: nil), "data-onchain-bundle") == [""]
  end

  defp button(blocked: blocked) do
    render_component(&SwapForm.wallet_step/1,
      id: "card-sender",
      next_step: @bid,
      steps: [@bid],
      bundle: true,
      blocked: blocked,
      check_event: "check_again"
    )
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".token-swap__wallet-step")
  end
end
