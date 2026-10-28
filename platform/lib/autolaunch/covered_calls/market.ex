defmodule Autolaunch.CoveredCalls.Market do
  @moduledoc """
  The four covered-call operations every surface calls — the page, the HTTP
  routes and the browser tools — so each answers with the same figures and the
  same refusals:

    * `:book` — a market's listings, as its contract holds them (public)
    * `:quote` — the suggested premium for a strike and expiry (public)
    * `:positions` — what a wallet of the acting account sold and holds
    * `:prepare` — the wallet steps for one action, for a wallet of the acting account

  Nothing is stored: the contract is the record. The acting account comes from
  the actor the caller authenticated; a wallet named in the request is only
  ever one of that account's own.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.CoveredCalls,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls.{Book, Positions, Quote, Signer, Steps}

  actions do
    action :book, :map do
      argument :symbol, :string, allow_nil?: false
      run fn input, _context -> Book.read(input.arguments.symbol) end
    end

    action :quote, :map do
      argument :symbol, :string, allow_nil?: false
      argument :strike_per_token, :integer, allow_nil?: false, constraints: [min: 1]
      argument :expiry, :integer, allow_nil?: false

      run fn input, _context ->
        Quote.suggest(input.arguments.symbol, input.arguments.strike_per_token, input.arguments.expiry)
      end
    end

    action :positions, :map do
      argument :symbol, :string, allow_nil?: false
      argument :wallet, :string

      run fn input, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, input.arguments[:wallet]),
             do: Positions.read(input.arguments.symbol, wallet)
      end
    end

    action :prepare, :map do
      argument :symbol, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: Steps.kinds()]
      argument :signer, :string
      argument :listing_id, :integer, constraints: [min: 1]
      argument :amount, :integer, constraints: [min: 1]
      argument :strike_per_token, :integer, constraints: [min: 1]
      argument :premium_per_token, :integer, constraints: [min: 1]
      argument :expiry, :integer

      run fn input, %{actor: actor} ->
        with {:ok, signer} <- Signer.wallet(actor, input.arguments[:signer]) do
          input.arguments
          |> Map.drop([:signer])
          |> Steps.prepare(signer)
          |> case do
            {:ok, prepared} -> {:ok, Map.put(prepared, :signer, signer)}
            error -> error
          end
        end
      end
    end
  end

  policies do
    policy action([:book, :quote]) do
      authorize_if always()
    end

    policy action([:positions, :prepare]) do
      authorize_if actor_present()
    end
  end
end
