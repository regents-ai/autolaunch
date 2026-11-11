defmodule Autolaunch.AuctionTerms do
  @moduledoc """
  The two figures an auction fixes when it is created and its reading job
  reads once: its floor price and its launch token's total supply. An auction
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
end
