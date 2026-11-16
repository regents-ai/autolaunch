defmodule Autolaunch.Earn.Steps do
  @moduledoc """
  The wallet steps for one Earn action, built on the server from the chain at
  the latest block, for a signer the caller has already proved is one of the
  acting account's own wallets (`Autolaunch.Earn.Product`):

    * `:deposit` — an exact USDC approval of the amount to the pool, then the
      pool's `supply(asset, amount, signer, 0)`, which credits the signer
    * `:withdraw` — the pool's `withdraw(asset, amount, signer)`, which sends the
      USDC to the signer; for everything the amount is `type(uint256).max`, so
      the balance as it stands when the step lands comes out, interest included

  Each step's calldata ends with the site's Builder Code (`RegentChain.Review.step/3`).
  The approval is always a step of its own, so it stays pressable once done;
  `approved` says whether the chain already holds it (`States.readiness/2`).
  A step the chain's own state makes certain to fail comes back with `blocked`
  naming the reason (`States.blocked/1`), and its steps are still built, so a
  press the chain has since allowed reaches the wallet. An amount that is not a
  whole number above zero, or everything for a deposit, is refused outright.
  """

  alias Autolaunch.Chain.{Abi, Client}
  alias Autolaunch.Earn.{Catalog, Chain, States}
  alias RegentChain.{Call, Review}

  @type prepared :: %{
          kind: States.kind(),
          product: Catalog.product(),
          chain: map(),
          terms: Chain.terms(),
          holding: Chain.holding(),
          withdrawal: States.withdrawal() | nil,
          units: non_neg_integer(),
          approved: boolean(),
          blocked: States.reason() | nil,
          steps: [map()]
        }

  @doc """
  What `request` (`product`, `kind`, and `amount` in the asset's smallest units
  or, for a withdrawal, `everything: true`) comes to for `signer` at the latest
  block, with its wallet steps.
  """
  @spec prepare(map(), String.t()) :: {:ok, prepared()} | {:error, atom()}
  def prepare(%{product: id, kind: kind} = request, signer) do
    with {:ok, product} <- Catalog.product(id),
         {:ok, asked} <- asked(kind, request),
         {:ok, lab} <- Catalog.lab(product),
         {:ok, terms, holding} <- Chain.read(product, lab, signer) do
      {:ok,
       kind
       |> built(asked, product, terms, holding)
       |> Map.merge(%{kind: kind, product: product, chain: Client.chain(lab), terms: terms})
       |> Map.put(:holding, holding)}
    end
  end

  # What the request asks for: an amount above zero to deposit, and to
  # withdraw either an amount or everything, never both.
  defp asked(:deposit, %{amount: units} = request) when is_integer(units) and units > 0,
    do: if(request[:everything] == true, do: {:error, :invalid_amount}, else: {:ok, units})

  defp asked(:withdraw, %{everything: true} = request),
    do:
      if(is_nil(request[:amount]),
        do: {:ok, States.withdrawal(:everything)},
        else: {:error, :invalid_amount}
      )

  defp asked(:withdraw, %{amount: units}) when is_integer(units) and units > 0,
    do: {:ok, States.withdrawal(units)}

  defp asked(_kind, _request), do: {:error, :invalid_amount}

  defp built(:deposit, units, product, terms, holding) do
    blocked =
      States.blocked(%{
        kind: :deposit,
        status: terms.status,
        units: units,
        funds: holding.usdc,
        capacity: terms.capacity
      })

    %{
      withdrawal: nil,
      units: units,
      approved: States.readiness(units, holding.allowance) == :approved,
      blocked: reason(blocked),
      steps: [
        Review.step(
          "usdc_approval",
          product.asset_address,
          Abi.encode_erc20("approve", [product.pool, units])
        ),
        Review.step(
          "supply",
          product.pool,
          Call.encode("supply(address,uint256,address,uint16)", [
            product.asset_address,
            units,
            holding.wallet,
            0
          ])
        )
      ]
    }
  end

  defp built(:withdraw, withdrawal, product, terms, holding) do
    blocked =
      States.blocked(%{
        kind: :withdraw,
        status: terms.status,
        position: holding.position,
        withdrawal: withdrawal,
        liquidity: terms.available
      })

    %{
      withdrawal: withdrawal,
      units: States.withdrawn(withdrawal, holding.balance),
      approved: true,
      blocked: reason(blocked),
      steps: [
        Review.step(
          "withdraw",
          product.pool,
          Call.encode("withdraw(address,uint256,address)", [
            product.asset_address,
            States.withdraw_units(withdrawal),
            holding.wallet
          ])
        )
      ]
    }
  end

  defp reason(:ok), do: nil
  defp reason({:blocked, reason}), do: reason
end
