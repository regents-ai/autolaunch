defmodule AutolaunchWeb.OnchainStepsRebuildTest do
  @moduledoc """
  What every wallet panel does when a step it sent did not go through
  (`AutolaunchWeb.OnchainSteps.rebuild_reverted/4`): the review on the page is
  built again from the chain once nothing else sent from it is on its way, so
  the next press never sends the transaction that just failed against a chain
  that has moved on.
  """
  use ExUnit.Case, async: true

  alias AutolaunchWeb.OnchainSteps
  alias RegentChain.{Presses, Review}

  @chain %{chain_id: 8453, name: "Base", rpc_url: "https://base.invalid"}
  @signer "0x" <> String.duplicate("11", 20)
  @to "0x" <> String.duplicate("22", 20)

  test "a step of the open review that reverted builds the review again" do
    review = review(["withdraw"])
    {socket, entry} = socket(review) |> sent(review, "withdraw", "a1") |> reverted()

    socket = OnchainSteps.rebuild_reverted(socket, entry, "did not go through", &rebuilt/1)

    assert socket.assigns.rebuilt
    assert socket.assigns.press_note == "did not go through"
  end

  test "while another step of that review is on its way, the review waits for it" do
    review = review(["approve", "pay"])
    {socket, approval} = socket(review) |> sent(review, "approve", "a1")
    {socket, _payment} = sent({socket, approval}, review, "pay", "a2")
    {socket, approval} = reverted({socket, approval})

    socket = OnchainSteps.rebuild_reverted(socket, approval, "did not go through", &rebuilt/1)

    refute socket.assigns.rebuilt
    assert socket.assigns.press_note == "did not go through"
  end

  test "a step from a review the page has left changes nothing" do
    earlier = review(["withdraw"], "earlier")
    {socket, entry} = socket(earlier) |> sent(earlier, "withdraw", "a1") |> reverted()
    socket = %{socket | assigns: %{socket.assigns | review: review(["withdraw"], "now")}}

    assert OnchainSteps.rebuild_reverted(socket, entry, "x", &rebuilt/1) == socket
  end

  test "the words go beside a review built again, or before the reason nothing was built" do
    open = OnchainSteps.rebuilt(socket(review(["withdraw"])), "did not go through")
    assert open.assigns.press_note =~ "did not go through"
    assert open.assigns.notice == nil

    refused =
      socket(nil)
      |> Phoenix.Component.assign(notice: "Nothing is waiting.")
      |> OnchainSteps.rebuilt("did not go through")

    assert refused.assigns.press_note == nil
    assert refused.assigns.notice == "did not go through Nothing is waiting."
  end

  defp review(steps, inputs \\ "now"),
    do:
      Review.new(
        "panel",
        @signer,
        @chain,
        Enum.map(steps, &Review.step(&1, @to, "0x12345678")),
        %{"form" => inputs}
      )

  defp socket(review) do
    presses = if review, do: Presses.remember(Presses.new(), review), else: Presses.new()

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        review: review,
        presses: presses,
        press_note: nil,
        notice: nil,
        rebuilt: false
      }
    }
  end

  # The page reports `name` of `review` sent, as `OnchainSteps.sent/2` takes it.
  defp sent({socket, _entry}, review, name, byte), do: sent(socket, review, name, byte)

  defp sent(socket, review, name, byte) do
    params = %{
      "review_id" => review.id,
      "step" => name,
      "transaction_hash" => "0x" <> String.duplicate(byte, 32)
    }

    {:ok, entry, presses} = Presses.sent(socket.assigns.presses, params)
    {put_presses(socket, presses), entry}
  end

  # Base reads the step back as reverted, as `OnchainSteps.checked/5` records it.
  defp reverted({socket, entry}) do
    {entry, presses} = Presses.checked(socket.assigns.presses, entry.hash, {:ok, :reverted})
    {put_presses(socket, presses), entry}
  end

  defp put_presses(socket, presses), do: %{socket | assigns: %{socket.assigns | presses: presses}}

  defp rebuilt(socket), do: Phoenix.Component.assign(socket, rebuilt: true)
end
