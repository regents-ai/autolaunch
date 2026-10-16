defmodule Autolaunch.Chain.CallsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.{Abi, Calls}
  alias RegentChain.Review

  # BATCH_IS_THE_REVIEWS_ONLY_WITH_EVERY_CALL: a transaction the wallet names
  # for a batch is the review's only when it carries every reviewed call's
  # target and calldata, in order, on the review's chain, for the review's
  # signer; a smart account's batch is done only when the entry point says the
  # signer's operation succeeded. Any other transaction is no answer about the
  # claim, so the page never says "Claimed" for it.

  defmodule Chain do
    def transaction(_chain, _hash), do: {:ok, Process.get(:tx)}
    def receipt(_chain, _hash), do: {:ok, Process.get(:receipt)}
  end

  @signer "0x1111111111111111111111111111111111111111"
  @bundler "0x9999999999999999999999999999999999999999"
  @locker "0x2222222222222222222222222222222222222222"
  @splitter "0x3333333333333333333333333333333333333333"
  @hash "0x" <> String.duplicate("ab", 32)
  @collect "0xddc1f59d" <> String.duplicate("0", 63) <> "1"
  @claim "0xd1058e59"

  test "BATCH_IS_THE_REVIEWS_ONLY_WITH_EVERY_CALL" do
    review =
      Review.new(
        "claim",
        @signer,
        %{chain_id: 31_338, name: "Robinhood", rpc_url: "http://127.0.0.1:8545"},
        [
          Review.step("collect_full_range", @locker, @collect),
          Review.step("claim", @splitter, @claim)
        ]
      )

    batched = batch([{@locker, @collect}, {@splitter, @claim}])

    # An account that batches itself sends the calls to its own address.
    assert outcome(review, tx(@signer, batched), "0x1") == {:ok, :confirmed}
    assert outcome(review, tx(@signer, batched), "0x0") == {:ok, :reverted}
    assert outcome(review, tx(@signer, batched), nil) == {:ok, :pending}

    # A call left out, the calls in another order, another chain, or another
    # account's batch is not this review's.
    refute_review(review, tx(@signer, batch([{@splitter, @claim}])))
    refute_review(review, tx(@signer, batch([{@splitter, @claim}, {@locker, @collect}])))
    refute_review(review, %{tx(@signer, batched) | "chainId" => "0x1"})
    refute_review(review, tx(@bundler, batched))

    # A smart account's batch names the signer and ends as the entry point says.
    from_bundler =
      tx(@bundler, "0x765e827f" <> word(@signer) <> String.trim_leading(batched, "0x"))

    assert outcome(review, from_bundler, "0x1", [operation(@signer, 1)]) == {:ok, :confirmed}
    assert outcome(review, from_bundler, "0x1", [operation(@signer, 0)]) == {:ok, :reverted}
    refute_review(review, from_bundler, [operation(@bundler, 1)])
  end

  defp outcome(review, tx, status, logs \\ []) do
    Process.put(:tx, tx)
    Process.put(:receipt, status && %{"status" => status, "logs" => logs})
    Calls.outcome(review, @hash, Chain)
  end

  defp refute_review(review, tx, logs \\ []),
    do: assert(outcome(review, tx, "0x1", logs) == {:error, :not_this_step})

  defp tx(from, input),
    do: %{"chainId" => "0x7a6a", "from" => from, "to" => from, "input" => input, "value" => "0x0"}

  # Each call as a smart account's execute list carries it: the target as a
  # word, then the calldata.
  defp batch(calls) do
    "0x34fcd5be" <>
      Enum.map_join(calls, fn {to, "0x" <> data} -> word(to) <> word("0x0") <> data end)
  end

  defp word("0x" <> hex), do: String.pad_leading(String.downcase(hex), 64, "0")

  defp operation(sender, success) do
    %{
      "topics" => [
        Abi.topic0("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"),
        @hash,
        "0x" <> word(sender),
        "0x" <> word("0x0")
      ],
      "data" =>
        "0x" <>
          word("0x1") <> word("0x" <> Integer.to_string(success)) <> word("0x0") <> word("0x0")
    }
  end
end
