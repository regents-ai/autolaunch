defmodule Autolaunch.CoveredCalls.BookTest do
  @moduledoc """
  The shared reading of a market is kept between visits, and a covered-call
  step that lands drops it, so the next read shows what the step changed. A
  wallet's positions never come from the kept reading.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.CoveredCalls.{Book, Positions}
  alias Autolaunch.CoveredCallsChain

  @unit CoveredCallsChain.unit()

  setup do
    previous = Application.get_env(:autolaunch, :covered_calls_book_kept_ms)
    Application.put_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
    :ok = Book.expire("AMZNc")

    on_exit(fn ->
      :ok = Book.expire("AMZNc")

      if previous,
        do: Application.put_env(:autolaunch, :covered_calls_book_kept_ms, previous),
        else: Application.delete_env(:autolaunch, :covered_calls_book_kept_ms)
    end)
  end

  test "a kept reading stays until a landed step drops it" do
    CoveredCallsChain.install()
    {:ok, before} = Book.read("AMZNc")
    assert [%{filled: filled}] = before.listings
    assert filled == 4 * @unit

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 5 * @unit})]})
    assert {:ok, %{listings: [%{filled: ^filled}]}} = Book.read("AMZNc")

    :ok = Book.expire("AMZNc")
    assert {:ok, %{listings: [%{filled: refilled}]}} = Book.read("AMZNc")
    assert refilled == 5 * @unit
  end

  test "a crowd asking to read again keeps a fresh reading: one read per ten seconds" do
    CoveredCallsChain.install()
    {:ok, %{chain_id: chain_id}} = Autolaunch.CoveredCalls.Deployment.current()
    {:ok, before} = Book.read("AMZNc")
    assert [%{filled: filled}] = before.listings

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 5 * @unit})]})
    for _visitor <- 1..5, do: Book.refresh(chain_id)
    assert {:ok, %{listings: [%{filled: ^filled}]}} = Book.read("AMZNc")
  end

  test "a wallet's positions are read at the latest block, never from the kept reading" do
    CoveredCallsChain.install()
    {:ok, kept} = Book.read("AMZNc")
    assert length(kept.listings) == 1

    # Someone lists again and the wallet buys into both, with no press on this site.
    CoveredCallsChain.put(%{
      listings: [CoveredCallsChain.listing(%{}), CoveredCallsChain.listing(%{filled: @unit})],
      held: @unit
    })

    wallet = "0x" <> String.duplicate("ab", 20)
    assert {:ok, positions} = Positions.read("AMZNc", wallet)
    assert Enum.map(positions.book.listings, & &1.id) == [1, 2]
    assert Enum.map(positions.holdings, & &1.listing_id) == [1, 2]
    assert {:ok, %{listings: [_only]}} = Book.read("AMZNc")
  end
end
