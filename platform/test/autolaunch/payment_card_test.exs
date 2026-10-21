defmodule Autolaunch.PaymentCardTest do
  @moduledoc """
  The Make a payment card on a Revstake token's page, read through the real
  Base reader from a scripted chain: the launch's token, splitter, payment
  receiver and treasury come from the strategy's own record of the launch;
  the reader takes every binding, balance and allowance at one block; and a
  review exists only when the receiver is the launch's canonical one, on the
  deployment's own network.
  """
  use Autolaunch.DataCase, async: false

  import AutolaunchWeb.SessionAuthorityHelpers, only: [leased: 1]

  alias Autolaunch.{BaseRpcStub, LabAbi, SubjectWalletActions, TestSupport}
  alias Autolaunch.Chain.{Abi, SubjectAbi}

  @auction "0x" <> String.duplicate("a1", 20)
  @token "0x5100000000000000000000000000000000000051"
  @splitter "0x5400000000000000000000000000000000000054"
  @receiver "0x5500000000000000000000000000000000000055"
  @treasury "0x5300000000000000000000000000000000000053"
  @usdc_unit 1_000_000

  defmodule Chain do
    @moduledoc false
    alias Autolaunch.{BaseRpcStub, LabAbi}
    alias Autolaunch.Chain.{Abi, SubjectAbi}

    def install(answers) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      :persistent_term.put(__MODULE__, answers)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"

    defp answer("eth_getBlockByNumber", _params),
      do: %{
        "number" => "0x96",
        "hash" => "0x" <> String.duplicate("ab", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_call", [%{to: to, data: data}, _block]) do
      words =
        Map.fetch!(
          :persistent_term.get(__MODULE__),
          {String.downcase(to), String.slice(data, 0, 10), String.slice(data, 10..-1//1)}
        )

      "0x" <> Enum.map_join(List.wrap(words), &BaseRpcStub.hex_word/1)
    end

    def word(address), do: address |> String.trim_leading("0x") |> String.to_integer(16)

    def arg(address),
      do: address |> String.trim_leading("0x") |> String.downcase() |> String.pad_leading(64, "0")

    def read(id), do: SubjectAbi.selector(id)

    def erc20("balance_of"), do: "0x70a08231"
    def erc20("allowance"), do: "0xdd62ed3e"

    def distribution, do: LabAbi.selector("distribution(address)")
  end

  setup do
    account = TestSupport.register_creator!()
    auction = TestSupport.project_auction(chain_id: 8453, state: :graduated, address: @auction)
    wallet = String.downcase(account.wallet_address)
    {:ok, account: account, auction: auction, wallet: wallet}
  end

  defp chain(wallet, overrides \\ %{}) do
    usdc = String.downcase(Abi.usdc_address())
    regent = String.downcase(Abi.regent_address())

    strategy =
      Autolaunch.Lab.current!() |> Autolaunch.Lab.address!(:strategy) |> String.downcase()

    beneficiary = Map.get(overrides, :beneficiary, @treasury)

    # The strategy's record of a migrated launch: subject, escrow, treasury,
    # splitter, receiver, pool id and position.
    distribution =
      [2, 0, 0, 0, 100, 0, 0, 0, 0, 1, Chain.word(@token), 0x52, Chain.word(@treasury)] ++
        [Chain.word(@splitter), Chain.word(@receiver), 0xABC, 1]

    %{
      {strategy, Chain.distribution(), Chain.arg(@auction)} => distribution,
      {@splitter, Chain.read(:subject), ""} => Chain.word(@token),
      {@splitter, Chain.read(:usdc), ""} => Chain.word(usdc),
      {@splitter, Chain.read(:regent), ""} => Chain.word(regent),
      {@splitter, Chain.read(:treasury), ""} => Chain.word(@treasury),
      {@splitter, Chain.read(:total_staked), ""} => 1_000,
      {@splitter, Chain.read(:staked_of), Chain.arg(wallet)} => 0,
      {@receiver, Chain.read(:splitter), ""} => Chain.word(@splitter),
      {@receiver, Chain.read(:subject), ""} => Chain.word(@token),
      {@receiver, Chain.read(:usdc), ""} => Chain.word(usdc),
      {@receiver, Chain.read(:regent), ""} => Chain.word(regent),
      {@receiver, Chain.read(:treasury), ""} => Chain.word(@treasury),
      {@receiver, Chain.read(:beneficiary), ""} => Chain.word(beneficiary),
      {@receiver, Chain.read(:note_editor), ""} => Chain.word(@treasury),
      {@receiver, Chain.read(:referral_bps), ""} => 0,
      {@receiver, Chain.read(:receiver_note), ""} => Chain.word(@receiver),
      {usdc, Chain.erc20("allowance"), Chain.arg(wallet) <> Chain.arg(@receiver)} => 0
    }
    |> Map.merge(
      for asset <- [@token, usdc, regent],
          holder <- [wallet, @receiver],
          into: %{} do
        {{asset, Chain.erc20("balance_of"), Chain.arg(holder)}, 50 * @usdc_unit}
      end
    )
    |> Map.merge(
      for asset <- [@token, usdc, regent], into: %{} do
        {{@splitter, Chain.read(:claimable), Chain.arg(wallet) <> Chain.arg(asset)}, 0}
      end
    )
  end

  test "a Revstake launch's payment review comes from its own record and the real reader",
       %{account: account, auction: auction, wallet: wallet} do
    Chain.install(chain(wallet))

    assert {:ok, state} = SubjectWalletActions.wallet_state(auction.id, wallet)
    assert state.receiver.address == @receiver
    assert state.balances.usdc == "50"

    assert {:ok, %{steps: [approval, payment], facts: facts}} =
             SubjectWalletActions.prepare(
               auction.id,
               wallet,
               :pay,
               %{"asset" => "usdc", "amount" => "1"},
               leased(account.id)
             )

    assert approval.step == "approval"
    assert payment.step == "action"
    assert facts.receiver == @receiver
    assert facts.amount == "1"
    assert facts.auction_id == auction.id
  end

  test "a receiver whose money goes anywhere but the launch's treasury is refused",
       %{account: account, auction: auction, wallet: wallet} do
    Chain.install(chain(wallet, %{beneficiary: "0x" <> String.duplicate("66", 20)}))

    assert {:error, %{reason: :receiver_not_canonical}} =
             SubjectWalletActions.prepare(
               auction.id,
               wallet,
               :pay,
               %{"asset" => "usdc", "amount" => "1"},
               leased(account.id)
             )
  end

  test "a deployment on another network refuses a Base launch's payment review",
       %{account: account, auction: auction, wallet: wallet} do
    Chain.install(chain(wallet))

    description =
      Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("chain_id", 84_532)

    path =
      Path.join(System.tmp_dir!(), "payment-card-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(description))
    previous = Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)
    Application.put_env(:autolaunch, :autolaunch_base_deployment, path)

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_base_deployment, previous)
      File.rm(path)
    end)

    assert {:error, %{reason: :review_network_mismatch}} =
             SubjectWalletActions.prepare(
               auction.id,
               wallet,
               :pay,
               %{"asset" => "usdc", "amount" => "1"},
               leased(account.id)
             )
  end
end
