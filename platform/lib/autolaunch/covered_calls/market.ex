defmodule Autolaunch.CoveredCalls.Market do
  @moduledoc """
  The covered-call operations, so every surface answers with the same
  figures and the same refusals:

    * `:book` — a market's listings and bids, as its contract holds them (public)
    * `:offer` — one listing or bid by its id, at the latest block, for a
      page's link to one the book does not offer (public)
    * `:quote` — a seller's quote for an expiry: the reference price, the
      next expiries, three suggested strikes, and what a listing of the
      chosen strike and premium pays (public)
    * `:positions` — what a wallet of the acting account sold, holds and bid
    * `:prepare` — the wallet steps for one action, for a wallet of the acting account

  The page reads `:book`, `:offer`, `:positions` and `:prepare` as they are. Every agent
  surface (the HTTP routes, which the browser tools call, and the hosted MCP
  tools) runs `:book_answer`, `:quote`, `:positions_answer` and
  `:prepare_answer`: the same operation, its answer shaped once
  (`Autolaunch.CoveredCalls.Answer`), and only while the site offers covered
  calls (`Autolaunch.CoveredCalls.Checks.Offered`), the steps only once the
  site has left prelaunch read-only mode
  (`Autolaunch.CoveredCalls.Checks.LaunchesOpen`). A refusal is an
  `Autolaunch.CoveredCalls.Refused` naming its reason.

  Nothing is stored: the contract is the record. The acting account comes from
  the actor the caller authenticated; a wallet named in the request is only
  ever one of that account's own.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.CoveredCalls,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Answer, Book, Positions, Quote, Refused, Signer, Steps}

  # Bounds a contract call can carry: amounts and prices far beyond any real
  # one, and an expiry as the contract's uint64.
  @amount [min: 1, max: 2 ** 128 - 1]
  @expiry [min: 0, max: 2 ** 64 - 1]

  # What each input of the hosted tools is, in the browser tools' words
  # (priv/covered_calls_tools.json).
  @symbol "The stock token's symbol exactly as the site lists it, such as AMZNc."

  actions do
    action :book, :map do
      argument :symbol, :string, allow_nil?: false
      run fn input, _context -> input.arguments.symbol |> Book.read() |> __MODULE__.refused() end
    end

    action :offer, :map do
      argument :symbol, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: [:listing, :bid]]
      argument :id, :integer, allow_nil?: false, constraints: [min: 1]

      run fn %{arguments: %{symbol: symbol, kind: kind, id: id}}, _context ->
        symbol |> Book.one(kind, id) |> __MODULE__.refused()
      end
    end

    action :quote, :map do
      argument :symbol, :string, allow_nil?: false, description: @symbol

      argument :expiry, :integer,
        allow_nil?: false,
        constraints: @expiry,
        description:
          "One of the next four Fridays at 21:00 UTC a quote offers, as Unix seconds; Fridays when the US stock market is shut or closes early are left out, and listings take no other expiry."

      argument :amount, :integer,
        constraints: @amount,
        description:
          "Raw stock units to list; unit raw units make one whole token. Leave it out for the per-token figures only."

      argument :strike_per_token, :integer,
        constraints: @amount,
        description:
          "The strike in micro-USDC (6 decimals) per whole token. Leave it out for the middle suggested strike."

      argument :premium_per_token, :integer,
        constraints: @amount,
        description:
          "The premium the listing asks, in micro-USDC per whole token. Leave it out for the suggested premium."

      run fn input, _context -> input.arguments |> Quote.read() |> __MODULE__.refused() end
    end

    action :positions, :map do
      argument :symbol, :string, allow_nil?: false
      argument :wallet, :string

      run fn input, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, input.arguments[:wallet]) do
          Positions.read(input.arguments.symbol, wallet)
        end
        |> __MODULE__.refused()
      end
    end

    action :prepare, :map do
      argument :symbol, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: Steps.kinds()]
      argument :signer, :string
      argument :listing_id, :integer, constraints: @amount
      argument :bid_id, :integer, constraints: @amount
      argument :amount, :integer, constraints: @amount
      argument :strike_per_token, :integer, constraints: @amount
      argument :premium_per_token, :integer, constraints: @amount
      argument :expiry, :integer, constraints: @expiry

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
        |> __MODULE__.refused()
      end
    end

    action :book_answer, :map do
      description "A market's listings and open bids, as its contract holds them at the latest block."
      argument :symbol, :string, allow_nil?: false, description: @symbol

      run fn input, context ->
        input.arguments.symbol
        |> CoveredCalls.read_covered_call_book(Ash.Context.to_opts(context))
        |> Answer.book()
      end
    end

    action :positions_answer, :map do
      description "What the acting account's wallet sold, holds and bid on a market."
      argument :symbol, :string, allow_nil?: false, description: @symbol

      run fn input, context ->
        input.arguments.symbol
        |> CoveredCalls.read_covered_call_positions(Ash.Context.to_opts(context))
        |> Answer.positions()
      end
    end

    action :prepare_answer, :map do
      description "The wallet steps for one covered-call action, for a wallet of the acting account."
      argument :symbol, :string, allow_nil?: false, description: @symbol

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: Steps.kinds()],
        description:
          "The action: list, fill, cancel, exercise, claim, collect_strike, bid, raise_bid, cancel_bid, refund_bid or sell_to_bid."

      argument :signer, :string,
        description:
          "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

      argument :listing_id, :integer,
        constraints: @amount,
        description:
          "The listing's number on this market, for fill, cancel, exercise, claim and collect_strike."

      argument :bid_id, :integer,
        constraints: @amount,
        description:
          "The bid's number on this market, for raise_bid, cancel_bid, refund_bid and sell_to_bid."

      argument :amount, :integer,
        constraints: @amount,
        description:
          "Raw stock token units: to list, to buy (fill), to exercise, to bid for, to add to a bid (raise_bid) or to sell into a bid (sell_to_bid)."

      argument :strike_per_token, :integer,
        constraints: @amount,
        description: "For list and bid: the strike in micro-USDC per whole token."

      argument :premium_per_token, :integer,
        constraints: @amount,
        description:
          "For list: the minimum premium; for bid: the premium offered; in micro-USDC per whole token."

      argument :expiry, :integer,
        constraints: @expiry,
        description:
          "For list and bid: one of the next four Fridays at 21:00 UTC a quote offers, as Unix seconds; Fridays when the US stock market is shut or closes early are left out."

      run fn %{arguments: %{symbol: symbol, kind: kind} = arguments}, context ->
        symbol
        |> CoveredCalls.prepare_covered_call_steps(
          kind,
          Map.drop(arguments, [:symbol, :kind]),
          Ash.Context.to_opts(context)
        )
        |> Answer.prepare()
      end
    end
  end

  # Ash turns a bare `{:error, atom}` into text, so a refusal is handed over as
  # an error that keeps its atom (`Autolaunch.CoveredCalls.reason/1`).
  @doc false
  def refused({:error, reason}) when is_atom(reason),
    do: {:error, Refused.exception(reason: reason)}

  def refused(result), do: result

  policies do
    policy action([:book, :offer, :quote, :book_answer]) do
      authorize_if always()
    end

    policy action([:positions, :prepare, :positions_answer, :prepare_answer]) do
      authorize_if actor_present()
    end

    # What every agent surface runs, only while the site offers covered calls,
    # and never by an app connected to a person's account calling as itself: its
    # token is for its identity tools alone (`Autolaunch.Agents.Connection`).
    # Paired, it calls as its agent instead.
    policy action([:book_answer, :quote, :positions_answer, :prepare_answer]) do
      forbid_unless Autolaunch.CoveredCalls.Checks.Offered
      forbid_if actor_attribute_equals(:role, :connected_app)
      authorize_if always()
    end

    # Wallet steps wait for the site to leave prelaunch read-only mode, as the
    # HTTP steps route does (`AutolaunchWeb.Prelaunch`).
    policy action(:prepare_answer) do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
