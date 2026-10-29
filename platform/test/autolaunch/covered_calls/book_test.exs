defmodule Autolaunch.CoveredCalls.BookTest do
  @moduledoc """
  The shared reading of a market is kept between visits, and a covered-call
  step that lands drops it, so the next read shows what the step changed.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.CoveredCalls.Book
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
end
