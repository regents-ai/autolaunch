defmodule Autolaunch.Earn.SharedTermsTest do
  @moduledoc """
  The market reading every visitor shares while it is kept: readers at the
  same moment wait for one reading, a later reader within the time it is kept
  gets that same reading, a reading that fails is never kept, and a landed
  step moves every later reader to a new one.
  """

  use ExUnit.Case, async: false

  alias Autolaunch.{Earn, EarnChain}
  alias Autolaunch.Earn.SharedTerms

  @unit EarnChain.unit()

  setup do
    EarnChain.install()
    Application.put_env(:autolaunch, :earn_terms_kept_ms, 60_000)
    {:ok, _cleared} = Cachex.clear(SharedTerms.cache())

    on_exit(fn ->
      Application.put_env(:autolaunch, :earn_terms_kept_ms, 0)
      Cachex.clear(SharedTerms.cache())
    end)
  end

  test "readers at the same moment wait for one reading of the market" do
    EarnChain.put(%{hold: self()})
    readers = for _reader <- 1..2, do: Task.async(fn -> Earn.read_earn_terms("aave-usdc") end)

    assert_receive {:earn_chain_held, reading}
    refute_receive {:earn_chain_held, _another}, 100
    send(reading, :go)

    assert [{:ok, %{terms: terms}}, {:ok, %{terms: terms}}] = Task.await_many(readers)
  end

  test "a later reader gets the kept reading, and a landed step moves on to a new one" do
    assert {:ok, %{terms: first}} = Earn.read_earn_terms("aave-usdc")

    EarnChain.put(%{supplied: 7 * @unit})
    assert {:ok, %{terms: ^first}} = Earn.read_earn_terms("aave-usdc")

    :ok = SharedTerms.subscribe("aave-usdc")
    SharedTerms.changed("aave-usdc")
    assert_receive {:earn_changed, "aave-usdc"}

    assert {:ok, %{terms: %{supplied: supplied}}} = Earn.read_earn_terms("aave-usdc")
    assert supplied == 7 * @unit
  end

  test "a reading that fails is not kept" do
    EarnChain.put(%{unreadable: true})
    assert {:error, error} = Earn.read_earn_terms("aave-usdc")
    assert Earn.reason(error) == :chain_unavailable

    EarnChain.put(%{})
    assert {:ok, %{terms: %{supplied: _supplied}}} = Earn.read_earn_terms("aave-usdc")
  end
end
