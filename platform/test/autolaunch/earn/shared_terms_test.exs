defmodule Autolaunch.Earn.SharedTermsTest do
  @moduledoc """
  The market reading every visitor shares while it is kept: readers at the
  same moment wait for one reading, a later reader within the time it is kept
  gets that same reading, a reading that fails is never kept, a landed step
  moves every later reader to a new one once for each transaction, on this
  machine and on one that hears of it, and a cache that cannot be used
  refuses the reading and still tells the pages.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.{Earn, EarnChain}
  alias Autolaunch.Earn.SharedTerms

  @unit EarnChain.unit()
  @hash "0x" <> String.duplicate("c", 64)

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
    :ok = SharedTerms.changed("aave-usdc", @hash)
    assert_receive {:earn_changed, "aave-usdc", @hash}

    assert {:ok, %{terms: %{supplied: supplied}}} = Earn.read_earn_terms("aave-usdc")
    assert supplied == 7 * @unit
  end

  test "a transaction reported again moves no reader on and tells no page" do
    :ok = SharedTerms.subscribe("aave-usdc")
    :ok = SharedTerms.changed("aave-usdc", @hash)
    assert_receive {:earn_changed, "aave-usdc", @hash}
    assert {:ok, %{terms: kept}} = Earn.read_earn_terms("aave-usdc")

    EarnChain.put(%{supplied: 9 * @unit})

    for _replay <- 1..3, do: :ok = SharedTerms.changed("aave-usdc", @hash)
    refute_receive {:earn_changed, _id, _hash}, 100
    assert {:ok, %{terms: ^kept}} = Earn.read_earn_terms("aave-usdc")

    # Another transaction is a step of its own.
    :ok = SharedTerms.changed("aave-usdc", "0x" <> String.duplicate("d", 64))
    assert_receive {:earn_changed, "aave-usdc", _another}
    assert {:ok, %{terms: %{supplied: supplied}}} = Earn.read_earn_terms("aave-usdc")
    assert supplied == 9 * @unit
  end

  test "one transaction reported many times at once moves readers on once and tells the pages once" do
    :ok = SharedTerms.subscribe("aave-usdc")
    assert {:ok, %{terms: before}} = Earn.read_earn_terms("aave-usdc")
    EarnChain.put(%{supplied: 7 * @unit})

    1..40
    |> Task.async_stream(fn _report -> SharedTerms.changed("aave-usdc", @hash) end,
      max_concurrency: 40
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    assert_receive {:earn_changed, "aave-usdc", @hash}
    refute_receive {:earn_changed, _id, _hash}, 100

    assert {:ok, %{terms: %{supplied: supplied} = after_step}} = Earn.read_earn_terms("aave-usdc")
    assert supplied == 7 * @unit and after_step != before

    # Moved on once: a reading taken now is the one kept since.
    EarnChain.put(%{supplied: 9 * @unit})
    assert {:ok, %{terms: ^after_step}} = Earn.read_earn_terms("aave-usdc")
  end

  test "a machine that hears of a step from another counts it once before its pages read" do
    # This machine keeps a reading from before the step, which landed on another.
    assert {:ok, %{terms: before}} = Earn.read_earn_terms("aave-usdc")
    EarnChain.put(%{supplied: 7 * @unit})

    # The first of its pages to hear of the step counts it here.
    :ok = SharedTerms.heard("aave-usdc", @hash)
    assert {:ok, %{terms: %{supplied: supplied} = after_step}} = Earn.read_earn_terms("aave-usdc")
    assert supplied == 7 * @unit
    assert after_step != before

    # Its other pages find it counted, and the same transaction reported here
    # tells no page again.
    EarnChain.put(%{supplied: 9 * @unit})
    :ok = SharedTerms.heard("aave-usdc", @hash)
    :ok = SharedTerms.subscribe("aave-usdc")
    :ok = SharedTerms.changed("aave-usdc", @hash)
    refute_receive {:earn_changed, _id, _hash}, 100
    assert {:ok, %{terms: ^after_step}} = Earn.read_earn_terms("aave-usdc")
  end

  test "a cache that can't be used refuses the reading, and a landed step is logged and still told" do
    cache = SharedTerms.cache()
    :ok = Supervisor.terminate_child(Autolaunch.Supervisor, cache)
    on_exit(fn -> Supervisor.restart_child(Autolaunch.Supervisor, cache) end)

    assert {:error, error} = Earn.read_earn_terms("aave-usdc")
    assert Earn.reason(error) == :chain_unavailable

    :ok = SharedTerms.subscribe("aave-usdc")

    log =
      capture_log(fn ->
        assert :ok = SharedTerms.changed("aave-usdc", @hash)
        assert :ok = SharedTerms.heard("aave-usdc", @hash)
      end)

    assert_receive {:earn_changed, "aave-usdc", @hash}
    # One warning for each step the cache could not count.
    assert length(Regex.scan(~r/landed step not counted/, log)) == 2

    {:ok, _cache} = Supervisor.restart_child(Autolaunch.Supervisor, cache)
    assert {:ok, %{terms: _terms}} = Earn.read_earn_terms("aave-usdc")
  end

  test "a reading that fails is not kept" do
    EarnChain.put(%{unreadable: true})
    assert {:error, error} = Earn.read_earn_terms("aave-usdc")
    assert Earn.reason(error) == :chain_unavailable

    EarnChain.put(%{})
    assert {:ok, %{terms: %{supplied: _supplied}}} = Earn.read_earn_terms("aave-usdc")
  end
end
