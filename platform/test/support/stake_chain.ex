defmodule Autolaunch.StakeChain do
  @moduledoc """
  The staking of two graduated Base launches for one test, a Revstake one and
  a Memestock one on the second Memestock launchpad, on a chain double that
  answers every read the token page's Stake and Claim views make at the
  latest block (0x20), by the function called and what it is asked about.
  Both launches trade the same token (`subject/0`) and stake it in the same
  staking contract (`splitter/0`):

    * the Revstake launch: the strategy's record of the migrated launch (its
      locked position, `lp_token_id/0`), the pool, and the LP locker's
      simulated `collect` of that position (2 REGENT and 1 of the token);
    * the Memestock launch (`launch_id/0`, made by the auction `auction/0`):
      the launchpad's record of it, trading against the stock `stock/0`
      (AAPLc, 8 decimals) with its full-range position (`memestock_lp/0`)
      and its token-only one above the opening price (`memestock_new_only/0`),
      each of whose simulated `collect` gives 2 AAPLc and 1 of the token; the
      hook's lanes (`lanes`: what waits for the creator, REGENT and the
      stakers, in the stock's smallest units) with nothing settled yet; the
      wallet the hook names to convert REGENT's lane (`converter`); and the
      stock's admission with its route (`route/0`), whose quote for any amount
      is `quote` USDC units;
    * one wallet's (`Autolaunch.BidFixture.wallet/0`) token `balance`, its
      `allowance` to the staking contract, what it has `staked` (everything
      staked there) and what it can claim of each asset (`claimable`, by
      asset: `:dollar`, USDC; `:token`; and `:currency`, REGENT on the
      Revstake launch and the stock on the Memestock one). Any other wallet
      holds, has staked and can claim nothing.

  Every other request goes to `Autolaunch.BaseRpcStub`. `install/1` points the
  site's Base client at it and `put/1` replaces what it answers mid-test, each
  as overrides over the defaults; both are undone when the test exits.
  `unavailable: true` fails every contract read, as a chain that cannot be
  reached just now. Amounts are smallest units.
  """

  alias Autolaunch.{BaseRpcStub, BidFixture, Lab, LabAbi}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @subject "0x9999999999999999999999999999999999999999"
  @escrow "0x7777777777777777777777777777777777777777"
  @splitter "0x8888888888888888888888888888888888888888"
  @receiver "0x6666666666666666666666666666666666666666"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @stock "0x5555555555555555555555555555555555555555"
  @auction "0x4444444444444444444444444444444444444444"
  @launcher "0x3333333333333333333333333333333333333333"
  @executor "0x2222222222222222222222222222222222222222"
  @route "0x1111111111111111111111111111111111111111"
  @lp_token_id 4_242
  @memestock_lp 4_343
  @memestock_new_only 4_344
  @launch_id 3
  @memestock_pool_id 11
  @q96 79_228_162_514_264_337_593_543_950_336
  @extsload "0x1e2eaeaf"
  @owner_of "0x6352211e"
  # A full range for a 60 tick spacing, and the token-only position's range:
  # every price of the token above the opening one, ticks below the pool's,
  # the token being its currency1.
  @full_range {-887_220, 887_220}
  @above_opening {-887_220, -60}

  def subject, do: @subject
  def splitter, do: @splitter
  def usdc, do: @usdc
  def stock, do: @stock
  def auction, do: @auction
  def route, do: @route
  def lp_token_id, do: @lp_token_id
  def memestock_lp, do: @memestock_lp
  def memestock_new_only, do: @memestock_new_only
  def launch_id, do: @launch_id

  @doc "The Memestock launch's pool id, as its record holds it."
  def memestock_pool_id, do: "0x" <> BaseRpcStub.hex_word(@memestock_pool_id)

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
            claimable: %{dollar: 0, token: 0, currency: 0},
            lanes: [0, 0, 0],
            converter: @executor,
            quote: 0
          },
          Map.new(overrides)
        )
    })
  end

  defp answer(_call, %{stake: %{unavailable: true}}), do: :unavailable

  defp answer(%{data: data}, %{stake: stake}) do
    selector = String.slice(data, 0, 10)
    arguments = data |> String.slice(10..-1//1) |> arguments()
    "0x" <> Enum.map_join(words(selector, arguments, stake), &BaseRpcStub.hex_word/1)
  end

  defp words(selector, arguments, stake) do
    case Enum.find(reads(stake), &(LabAbi.selector(elem(&1, 0)) == selector)) do
      {_signature, answer} -> answer.(arguments)
      nil when selector == @extsload -> [@q96]
      nil when selector == @owner_of -> owner(arguments)
    end
  end

  # Each read, by the function called, as a function of its arguments. The
  # site's deployments are read only by the answers that name one of their
  # contracts, so a test may take one apart.
  defp reads(stake) do
    [
      # The wallet's own figures.
      {"balanceOf(address)", &[own(&1, stake.balance)]},
      {"allowance(address,address)", &[own(&1, stake.allowance)]},
      {"stakedOf(address)", &[own(&1, stake.staked)]},
      {"claimable(address,address)",
       fn [asset, holder] -> [own([holder], Map.fetch!(stake.claimable, asset(asset)))] end},
      # The staking contract's, with the wallet its only staker.
      {"totalStaked()", fn _none -> [stake.staked] end},
      {"SKIM_BPS()", fn _none -> [200] end},
      {"usdc()", fn _none -> [word(@usdc)] end},
      {"dollar()", fn _none -> [word(@usdc)] end},
      # The locked positions'.
      {"positionInfo(uint256)", fn [id] -> [range(id)] end},
      {"getPositionLiquidity(uint256)", fn _id -> [0] end},
      {"collect(uint256)", fn [id] -> collected(id) end},
      # The Revstake launch's strategy, auction and treasury escrow.
      {"distribution(address)", fn _auction -> distribution() end},
      {"POOL_FEE()", fn _none -> [3_000] end},
      {"POOL_TICK_SPACING()", fn _none -> [60] end},
      {"remainingSupply()", fn _none -> [0] end},
      {"lifecycle()", fn _none -> [1] end},
      {"vestingStart()", fn _none -> [0x6000] end},
      {"VESTING_DURATION()", fn _none -> [365 * 86_400] end},
      {"totalReleased()", fn _none -> [0] end},
      # The Memestock launch's launchpad, hook and route.
      {"launchIdOfAuction(address)", fn _auction -> [@launch_id] end},
      {"launches(uint256)", fn [@launch_id] -> record() end},
      {"creatorReleasable(uint256)", fn [@launch_id] -> [0] end},
      {"stockAdmission(address)", fn _stock -> [1, 1, word(@route)] end},
      {"accrued(bytes32)", fn [@memestock_pool_id] -> stake.lanes end},
      {"settled(bytes32)", fn [@memestock_pool_id] -> [0, 0, 0, 0] end},
      {"executor()", fn _none -> [word(stake.converter)] end},
      {"quoteExactIn(address,address,uint256)", fn _sale -> [stake.quote] end}
    ]
  end

  # Who holds each locked position: the locker of its own launch.
  defp owner([@lp_token_id]) do
    {:ok, revstake} = Lab.contracts(Lab.current!(), :v2)
    [word(Lab.address!(revstake, :lp_locker))]
  end

  defp owner([id]) when id in [@memestock_lp, @memestock_new_only] do
    {:ok, memestock} = StocksLab.contracts(StocksLab.current!(), :v2)
    [word(memestock.locker)]
  end

  # A wallet's own figure for the fixture's wallet, and nothing for any other.
  defp own([holder | _rest], amount),
    do: if(holder == word(BidFixture.wallet()), do: amount, else: 0)

  defp asset(address) do
    cond do
      address == word(@usdc) -> :dollar
      address == word(@subject) -> :token
      address == word(@stock) -> :currency
      address == word(Lab.address!(Lab.current!(), :regent)) -> :currency
      true -> raise "the staking contract holds no asset at 0x#{BaseRpcStub.hex_word(address)}"
    end
  end

  # What collecting each position deposits: the REGENT pool's position 2 REGENT
  # (currency0) and 1 of the token; each of the stock pool's 2 AAPLc
  # (currency0) and 1 of the token.
  defp collected(@lp_token_id), do: [2 * 10 ** 18, 10 ** 18]

  defp collected(id) when id in [@memestock_lp, @memestock_new_only],
    do: [2 * 10 ** 8, 10 ** 18]

  defp range(@memestock_new_only), do: packed(@above_opening)
  defp range(id) when id in [@lp_token_id, @memestock_lp], do: packed(@full_range)

  # PositionInfo packs `tickUpper` at bit 32 and `tickLower` at bit 8, each a
  # 24-bit two's complement tick.
  defp packed({lower, upper}) do
    import Bitwise
    (upper &&& 0xFFFFFF) <<< 32 ||| (lower &&& 0xFFFFFF) <<< 8
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

  # The second launchpad's `launches` record of the graduated Memestock
  # launch, field by field in its version's word order.
  defp record do
    fields = %{
      launcher: word(@launcher),
      new_token: word(@subject),
      stock: word(@stock),
      auction: word(@auction),
      splitter: word(@splitter),
      start_block: 0x10,
      end_block: 0x18,
      claim_block: 0x19,
      migration_block: 0x1A,
      lifecycle: 2,
      pool_id: @memestock_pool_id,
      final_sqrt_price_x96: @q96,
      lp_token_id: @memestock_lp,
      lp_stock_used: 5 * 10 ** 8,
      lp_new_used: 7 * 10 ** 18,
      new_only_token_id: @memestock_new_only,
      new_only_used: 10 ** 18,
      vesting_start_block: 0x1A,
      creator_released: 0,
      retired_new: 0
    }

    Enum.map(StocksLabAbi.shape(:v2).record_fields, &Map.fetch!(fields, &1))
  end

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
