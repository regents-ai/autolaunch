defmodule Autolaunch.AuctionTerms do
  @moduledoc """
  The two figures an auction fixes when it is created and the market feeds
  read once: its floor price and its launch token's total supply. An auction
  row that already holds both keeps them without another read.

  Every launch token has 18 decimals.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @token_decimals 18

  @type t :: %{floor_price: String.t(), token_supply: Decimal.t()}

  @doc """
  The auction's floor price and token supply. `price` turns the contract's
  Q96 floor into quote-token units per token, as the feed formats its
  clearing price.
  """
  @spec read(map(), (non_neg_integer() -> String.t()), map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def read(%{floor_price: floor, token_supply: %Decimal{} = supply}, _price, _block, _opts)
      when is_binary(floor),
      do: {:ok, %{floor_price: floor, token_supply: supply}}

  def read(%{auction_address: auction}, price, block, opts) do
    with {:ok, floor} <- Rpc.call_uint(auction, LabAbi.selector("floorPrice()"), block, opts),
         {:ok, token} <- Rpc.call_address(auction, LabAbi.selector("token()"), block, opts),
         {:ok, supply} <- Rpc.call_uint(token, LabAbi.selector("totalSupply()"), block, opts) do
      {:ok,
       %{
         floor_price: price.(floor),
         token_supply: supply |> Rpc.format_units(@token_decimals) |> Decimal.new()
       }}
    end
  end

  @doc "Whether the auction row still lacks either figure."
  @spec missing?(map()) :: boolean()
  def missing?(auction), do: is_nil(auction.floor_price) or is_nil(auction.token_supply)

  @doc "Whether a reading of the amount raised differs from the row's."
  @spec raised_changed?(map(), String.t()) :: boolean()
  def raised_changed?(%{currency_raised: nil}, _raised), do: true

  def raised_changed?(%{currency_raised: stored}, raised),
    do: not Decimal.eq?(stored, Decimal.new(raised))

  @doc "The market fields a feed reading writes to its auction row."
  @spec fields(map()) :: map()
  def fields(%{minimum_reached: minimum_reached, currency_raised: raised, terms: terms}),
    do: %{
      minimum_reached: minimum_reached,
      currency_raised: raised,
      floor_price: terms.floor_price,
      token_supply: terms.token_supply
    }
end
