defmodule Autolaunch.Earn.Answer do
  @moduledoc """
  The Earn answers every agent surface gives, built once by the operations they
  run (`Autolaunch.Earn.Product`'s `:products_answer`, `:quote_answer`,
  `:positions_answer` and `:prepare_answer`): the HTTP routes send them as
  their `data`, and the hosted MCP tools as their result. Amounts are in the
  asset's smallest units (USDC has 6 decimals). Every answer names the block
  its figures were read at (`block`: number, hash, timestamp and `read_at`).

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered with `blocked` naming the reason, in code and words, beside the
  steps themselves. A refusal is an `Autolaunch.Earn.Refused` naming its reason.
  """

  alias Autolaunch.Earn
  alias Autolaunch.Earn.{Catalog, Refused}

  @ray 10 ** 27

  @blocked %{
    market_inactive: "This market is not active, so it takes no deposits and lets nothing out.",
    market_paused:
      "This market is paused, so nothing can be deposited or withdrawn until it resumes.",
    market_frozen:
      "This market is frozen: it takes no new deposits, and every balance can still be withdrawn.",
    not_enough_usdc: "This wallet holds less USDC than this deposit.",
    over_supply_cap: "This deposit would take the market past its supply cap.",
    over_balance: "This is more than the wallet's balance in this market.",
    not_available_now:
      "The market has less USDC available right now than this withdrawal; it frees up as borrowers repay."
  }

  @doc "Every product with its terms now and its risks, as every agent surface answers them."
  def products(read) do
    case Enum.find(read, &match?({:error, _}, &1)) do
      nil -> {:ok, %{products: Enum.map(read, fn {:ok, read} -> product(read) end)}}
      {:error, error} -> refused(error)
    end
  end

  @doc "What a wallet holds in each product, as every agent surface answers it."
  def positions(read) do
    case Enum.find(read, &match?({:error, _}, &1)) do
      nil ->
        held = Enum.map(read, fn {:ok, read} -> read end)

        {:ok,
         %{
           wallet: held |> hd() |> get_in([:holding, :wallet]),
           positions: Enum.map(held, &position/1)
         }}

      {:error, error} ->
        refused(error)
    end
  end

  @doc "A deposit's or withdrawal's preview, as every agent surface answers it."
  def quote({:ok, prepared}), do: {:ok, previewed(prepared)}
  def quote({:error, error}), do: refused(error)

  @doc "A deposit's or withdrawal's wallet steps, as every agent surface answers them."
  def prepare({:ok, prepared}),
    do:
      {:ok, prepared |> previewed() |> Map.merge(%{chain: prepared.chain, steps: prepared.steps})}

  def prepare({:error, error}), do: refused(error)

  @doc "A blocked reason in code and words."
  def blocked(nil), do: nil
  def blocked(reason), do: %{code: reason, message: Map.fetch!(@blocked, reason)}

  @doc "The market's yearly rate now as a percentage with two decimals, from its ray figure."
  @spec yearly_percent(non_neg_integer()) :: String.t()
  def yearly_percent(rate) do
    hundredths = div(rate * 10_000 + div(@ray, 2), @ray)

    "#{div(hundredths, 100)}.#{hundredths |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp product(%{product: product, terms: terms}) do
    product
    |> identity(terms)
    |> Map.merge(%{
      decimals: terms.decimals,
      status: terms.status,
      rate_now: %{ray: Integer.to_string(terms.rate), yearly_percent: yearly_percent(terms.rate)},
      supplied: terms.supplied,
      available: terms.available,
      supply_cap: if(terms.cap == 0, do: nil, else: terms.cap),
      room: room(terms.room),
      block: block(terms.block),
      risks: Catalog.risks(product)
    })
  end

  defp position(%{product: product, terms: terms, holding: holding}) do
    %{
      product: identity(product, terms),
      position: position_name(holding.position),
      balance: holding.balance,
      usdc: holding.usdc,
      allowance: holding.allowance,
      block: block(terms.block)
    }
  end

  defp previewed(%{product: product, terms: terms, holding: holding} = prepared) do
    %{
      kind: prepared.kind,
      product: identity(product, terms),
      signer: prepared.signer,
      amount: prepared.units,
      everything: prepared.withdrawal == :everything,
      approved: prepared.approved,
      blocked: blocked(prepared.blocked),
      wallet: %{
        balance: holding.balance,
        position: position_name(holding.position),
        usdc: holding.usdc,
        allowance: holding.allowance
      },
      market: %{status: terms.status, available: terms.available, room: room(terms.room)},
      block: block(terms.block)
    }
  end

  defp identity(product, terms),
    do:
      product
      |> Map.take([:id, :chain_id, :protocol, :market, :asset, :pool, :asset_address])
      |> Map.put(:market_token, terms.a_token)

  defp room(:uncapped), do: nil
  defp room({:room, left}), do: left
  defp room(:full), do: 0

  defp position_name(:none), do: :none
  defp position_name({:held, _balance}), do: :held

  defp block(block),
    do: %{
      number: block.number,
      hash: block.hash,
      timestamp: block.timestamp,
      read_at: block.timestamp |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }

  # A refusal the reading names keeps its reason.
  defp refused(error), do: {:error, Refused.exception(reason: Earn.reason(error))}
end
