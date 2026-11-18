defmodule Autolaunch.StakeChain do
  @moduledoc """
  A graduated Base Revstake launch's staking for one test, on a chain double
  that answers every read the token page's Stake and Claim views make at the
  latest block (0x20), by the function called: the strategy's record of the
  migrated launch (its token `subject/0`, its staking contract `splitter/0`
  and its locked position), the pool, the LP locker's simulated `collect` of
  that position (2 REGENT and 1 of the token), and one wallet's
  (`Autolaunch.BidFixture.wallet/0`) token `balance`, its `allowance` to the
  staking contract, what it has `staked`, and what it can claim of each asset
  (`claimable`, by asset: `:usdc`, `:token` and `:regent`). Any other wallet
  holds, has staked and can claim nothing. Every other request goes to
  `Autolaunch.BaseRpcStub`.

  `install/1` points the site's Base client at it and `put/1` replaces what it
  answers mid-test, each as overrides over the defaults; both are undone when
  the test exits. `unavailable: true` fails every contract read, as a chain
  that cannot be reached just now. Amounts are smallest units, 18 decimals
  for the token and REGENT and 6 for USDC.
  """

  alias Autolaunch.{BaseRpcStub, BidFixture, Lab, LabAbi}

  @subject "0x9999999999999999999999999999999999999999"
  @escrow "0x7777777777777777777777777777777777777777"
  @splitter "0x8888888888888888888888888888888888888888"
  @receiver "0x6666666666666666666666666666666666666666"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @lp_token_id 4_242
  @q96 79_228_162_514_264_337_593_543_950_336
  @extsload "0x1e2eaeaf"
  @owner_of "0x6352211e"

  def subject, do: @subject
  def splitter, do: @splitter
  def usdc, do: @usdc
  def lp_token_id, do: @lp_token_id

  @doc "Points the site's Base client at this chain for this test, `overrides` over the defaults."
  def install(overrides \\ %{}) do
    BaseRpcStub.install(:autolaunch_lab_http_client, &answer/2)

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x20",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => "0x6700"
        }
      }
    })

    put(overrides)
  end

  @doc "The chain from now on: `overrides` over the defaults."
  def put(overrides) do
    BaseRpcStub.put(%{
      stake:
        Map.merge(
          %{
            unavailable: false,
            balance: 0,
            allowance: 0,
            staked: 0,
            claimable: %{usdc: 0, token: 0, regent: 0}
          },
          Map.new(overrides)
        )
    })
  end

  defp answer(_call, %{stake: %{unavailable: true}}), do: :unavailable

  defp answer(%{data: data}, %{stake: stake}) do
    {:ok, config} = Lab.contracts(Lab.current!(), :v2)
    "0x" <> Enum.map_join(words(data, stake, config), &BaseRpcStub.hex_word/1)
  end

  defp words(data, stake, config) do
    selector = String.slice(data, 0, 10)
    arguments = data |> String.slice(10..-1//1) |> arguments()

    cond do
      selector == LabAbi.selector("balanceOf(address)") ->
        [own(arguments, stake.balance)]

      selector == LabAbi.selector("allowance(address,address)") ->
        [own(arguments, stake.allowance)]

      selector == LabAbi.selector("stakedOf(address)") ->
        [own(arguments, stake.staked)]

      selector == LabAbi.selector("claimable(address,address)") ->
        [asset, holder] = arguments
        [own([holder], Map.fetch!(stake.claimable, asset(asset, config)))]

      true ->
        Map.fetch!(pool(config), selector)
    end
  end

  # The pool's own reads, the same for every wallet.
  defp pool(config),
    do: %{
      LabAbi.selector("distribution(address)") => distribution(),
      LabAbi.selector("POOL_FEE()") => [3_000],
      LabAbi.selector("POOL_TICK_SPACING()") => [60],
      LabAbi.selector("remainingSupply()") => [0],
      @extsload => [@q96],
      @owner_of => [word(Lab.address!(config, :lp_locker))],
      LabAbi.selector("totalStaked()") => [0],
      LabAbi.selector("SKIM_BPS()") => [200],
      LabAbi.selector("usdc()") => [word(@usdc)],
      LabAbi.selector("collect(uint256)") => [2 * 10 ** 18, 10 ** 18],
      LabAbi.selector("positionInfo(uint256)") => [full_range()],
      LabAbi.selector("getPositionLiquidity(uint256)") => [0],
      LabAbi.selector("lifecycle()") => [1],
      LabAbi.selector("vestingStart()") => [0x6000],
      LabAbi.selector("VESTING_DURATION()") => [365 * 86_400],
      LabAbi.selector("totalReleased()") => [0]
    }

  # A wallet's own figure for the fixture's wallet, and nothing for any other.
  defp own([holder | _rest], amount),
    do: if(holder == word(BidFixture.wallet()), do: amount, else: 0)

  defp asset(address, config) do
    cond do
      address == word(@usdc) -> :usdc
      address == word(@subject) -> :token
      address == word(Lab.address!(config, :regent)) -> :regent
    end
  end

  defp arguments(hex), do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  # The strategy's seventeen-word `distribution` record of a migrated launch.
  defp distribution do
    [
      0,
      0,
      0,
      0,
      10,
      0,
      5 * 10 ** 18,
      7 * 10 ** 18,
      @q96,
      0,
      word(@subject),
      word(@escrow),
      0,
      word(@splitter),
      word(@receiver),
      1,
      @lp_token_id
    ]
  end

  # PositionInfo packs `tickUpper` at bit 32 and `tickLower` at bit 8, each a
  # 24-bit two's complement tick; full range for a 60 tick spacing.
  defp full_range do
    import Bitwise
    tick = 887_220
    (tick &&& 0xFFFFFF) <<< 32 ||| (-tick &&& 0xFFFFFF) <<< 8
  end

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
