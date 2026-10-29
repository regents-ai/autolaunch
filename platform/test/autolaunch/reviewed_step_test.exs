defmodule Autolaunch.ReviewedStepTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, LaunchActions}
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions
  alias RegentChain.{BuilderCode, Review}

  # REVIEWED_STEP_IS_THE_SAVED_STEP: a launch page asks the wallet for the saved
  # review's step exactly, Builder Code suffix included once, and a sent
  # transaction is the review's whatever Builder Code suffix the wallet left on
  # it. Rebuilding the saved step added the suffix a second time, so the sent
  # launch never matched its review and was left unlisted.

  @signer "0x1111111111111111111111111111111111111111"
  @launchpad "0x7777777777777777777777777777777777777777"
  @hash "0x" <> String.duplicate("ab", 32)
  @call "0xd1058e59" <> String.duplicate("0", 63) <> "7"
  # Another app's code in the same ERC-8021 schema 0 shape.
  @other_suffix Base.encode16("other" <> <<5, 0>>, case: :lower) <>
                  String.duplicate("8021", 8)

  test "the page's launch step is the saved step" do
    saved = "launch" |> Review.step(@launchpad, @call) |> Jason.encode!() |> Jason.decode!()

    review = %{
      "chain" => %{"chain_id" => 8453, "name" => "Base", "rpc_url" => "http://127.0.0.1:8545"},
      "signer" => @signer,
      "step" => saved,
      "facts" => %{}
    }

    for actions <- [LaunchActions, StocksLaunchActions] do
      assert %{steps: [step]} = actions.reviewed(%{action_id: "a", review: review})
      assert step.data == BuilderCode.append(@call)

      assert step == %{
               kind: "transaction",
               step: "launch",
               to: @launchpad,
               data: saved["data"],
               value: "0x0"
             }
    end
  end

  test "a sent launch is the review's with the suffix kept, dropped or rewritten" do
    BaseRpcStub.install(:wallet_http_client, fn _data, _state -> "0x" end)

    for input <- [BuilderCode.append(@call), @call, @call <> @other_suffix] do
      BaseRpcStub.put(%{
        receipts: %{@hash => BaseRpcStub.receipt(@hash, "0x10", [])},
        transactions: %{
          @hash => %{
            "hash" => @hash,
            "from" => @signer,
            "to" => @launchpad,
            "input" => input,
            "value" => "0x0"
          }
        }
      })

      assert Rpc.submission_status(@hash, @signer, @launchpad, BuilderCode.append(@call)) ==
               {:ok, :success}
    end

    BaseRpcStub.put(%{
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "from" => @signer,
          "to" => @launchpad,
          "input" => "0xd1058e59" <> String.duplicate("0", 63) <> "8",
          "value" => "0x0"
        }
      }
    })

    assert Rpc.submission_status(@hash, @signer, @launchpad, BuilderCode.append(@call)) ==
             {:error, :transaction_mismatch}
  end
end
