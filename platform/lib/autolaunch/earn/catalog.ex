defmodule Autolaunch.Earn.Catalog do
  @moduledoc """
  What Earn offers: each product as plain data from `config :autolaunch,
  :earn_products` (its id, chain, protocol, market, asset and the asset's
  decimals, and the addresses of its pool and asset), and whether the site
  offers Earn at all (`AUTOLAUNCH_EARN=true`, `enabled?/0`). Everything else
  about a product is read from the chain at the latest block each time
  (`Autolaunch.Earn.Chain`), which refuses a market whose decimals are not
  the catalog's.

  A product is read on the site's Base deployment (`Autolaunch.Lab.current/0`):
  Base itself, or a local fork of Base (`Autolaunch.Lab.test_chain?/1`), which
  carries the same contracts at the same addresses.
  """

  alias Autolaunch.Lab

  @type product :: %{
          id: String.t(),
          chain_id: pos_integer(),
          protocol: String.t(),
          market: String.t(),
          asset: String.t(),
          decimals: pos_integer(),
          pool: String.t(),
          asset_address: String.t()
        }

  @doc "Whether the site offers Earn."
  def enabled?, do: Application.get_env(:autolaunch, :earn, :off) == :on

  @doc "Every product, in the catalog's order."
  @spec products() :: [product()]
  def products, do: Application.fetch_env!(:autolaunch, :earn_products)

  @doc "The product with `id`, matched exactly."
  @spec product(term()) :: {:ok, product()} | {:error, :unknown_product}
  def product(id) when is_binary(id) do
    case Enum.find(products(), &(&1.id == id)) do
      nil -> {:error, :unknown_product}
      product -> {:ok, product}
    end
  end

  def product(_id), do: {:error, :unknown_product}

  @doc """
  The Base deployment `product` is read on, or `:earn_unavailable`: Earn is
  switched off, the site has no Base deployment it can read, or that
  deployment is on another chain.
  """
  @spec lab(product()) :: {:ok, map()} | {:error, :earn_unavailable}
  def lab(product) do
    with true <- enabled?(),
         {:ok, %{chain_id: chain_id} = lab} <- Lab.current(),
         true <- chain_id == product.chain_id or Lab.test_chain?(chain_id) do
      {:ok, lab}
    else
      false -> {:error, :earn_unavailable}
      {:error, _no_deployment} -> {:error, :earn_unavailable}
    end
  end

  @doc """
  The risks of lending through a product, in plain words, as the page and every
  agent answer give them.
  """
  @spec risks(product()) :: [String.t()]
  def risks(%{protocol: protocol, asset: asset}) do
    [
      "The rate changes. It moves with how much #{asset} is borrowed, and it can fall.",
      "A withdrawal depends on how much #{asset} is available at that moment. When most of it is lent out, you may have to wait for borrowers to repay.",
      "#{protocol}'s contracts, or the assets borrowers pledge, could fail, and money could be lost.",
      "Autolaunch never holds your funds and charges nothing. Your wallet deals with #{protocol} directly."
    ]
  end
end
