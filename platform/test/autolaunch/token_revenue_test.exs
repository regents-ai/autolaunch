defmodule Autolaunch.TokenRevenueTest do
  @moduledoc """
  A Revstake token's revenue is what its splitter's `RevenueRecognized` logs
  say, recorded by the same pass and under the same cursor as its trades,
  read from a scripted Base chain: a graduated launch whose splitter
  recognized one USDC payment.
  """
  use Autolaunch.DataCase, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, TestSupport, TokenTrades}

  @splitter "0x5400000000000000000000000000000000000054"
  @subject "0x5100000000000000000000000000000000000051"
  @payment "0x" <> String.duplicate("ab", 32)
  @revenue "RevenueRecognized(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)"

  defmodule Chain do
    @moduledoc false
    alias Autolaunch.BaseRpcStub

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getBlockByNumber", ["latest", _full?]), do: block(120)

    defp answer("eth_getBlockByNumber", ["0x" <> number, _full?]),
      do: block(String.to_integer(number, 16))

    # The strategy's record of a migrated launch: migrated at block 100, its
    # subject token, splitter and pool.
    defp answer("eth_call", [_call, _block]) do
      words =
        [2, 0, 0, 0, 100, 0, 0, 0, 0, 1, 0x51 * Integer.pow(2, 152) + 0x51, 0x52, 0x53] ++
          [0x54 * Integer.pow(2, 152) + 0x54, 0x55, 0xABC, 1]

      "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end

    # The splitter's one payment, at block 110, when the range holds it.
    defp answer("eth_getLogs", [%{address: address, fromBlock: from, toBlock: to}]) do
      if String.downcase(address) == "0x5400000000000000000000000000000000000054" and
           quantity(from) <= 110 and 110 <= quantity(to),
         do: [Autolaunch.TokenRevenueTest.revenue_log()],
         else: []
    end

    defp quantity("0x" <> hex), do: String.to_integer(hex, 16)

    def block(number),
      do: %{
        "number" => "0x" <> Integer.to_string(number, 16),
        "hash" => hash(number),
        "timestamp" => "0x" <> Integer.to_string(1_760_000_000 + number, 16)
      }

    def hash(number), do: "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0")
  end

  # One USDC recognized at block 110: 1.00 gross, 0.02 skimmed, 0.49 to
  # stakers and 0.49 to the treasury.
  def revenue_log do
    usdc = Autolaunch.Chain.Abi.usdc_address() |> String.trim_leading("0x") |> String.downcase()

    %{
      "removed" => false,
      "address" => @splitter,
      "blockNumber" => "0x6e",
      "blockHash" => Chain.hash(110),
      "logIndex" => "0x3",
      "transactionHash" => @payment,
      "topics" => [
        LabAbi.topic(@revenue),
        "0x" <> String.pad_leading(usdc, 64, "0"),
        "0x" <> String.pad_leading("99", 64, "0"),
        "0x" <> String.duplicate("0", 64)
      ],
      "data" =>
        "0x" <>
          Enum.map_join([1_000_000, 20_000, 980_000, 490_000, 490_000], &BaseRpcStub.hex_word/1)
    }
  end

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Chain)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)
  end

  test "a Revstake token's pass records its splitter's revenue with its trades" do
    auction =
      TestSupport.project_auction(
        chain_id: 8453,
        state: :graduated,
        token_address: @subject
      )

    token =
      [auction_id: auction.id, graduated_at: DateTime.utc_now()]
      |> TestSupport.project_token()
      |> Ash.load!(:auction, authorize?: false)

    assert :ok = TokenTrades.read(token)

    assert {:ok, [revenue]} = Autolaunch.token_revenue(token.id, actor: nil)
    assert revenue.asset_symbol == "USDC"
    assert Decimal.equal?(revenue.amount, Decimal.new("1"))
    assert Decimal.equal?(revenue.staker_share, Decimal.new("0.49"))
    assert revenue.transaction_hash == @payment
    assert revenue.block_number == 110

    # The next pass starts after the blocks this one read, so the payment is
    # never counted twice.
    reread = Ash.load!(Ash.reload!(token, authorize?: false), :auction, authorize?: false)
    assert reread.trades_next_block == 121
    assert :ok = TokenTrades.read(reread)
    assert {:ok, [_one]} = Autolaunch.token_revenue(token.id, actor: nil)
  end
end
