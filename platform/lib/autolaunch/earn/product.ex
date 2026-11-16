defmodule Autolaunch.Earn.Product do
  @moduledoc """
  The Earn operations, so every surface answers with the same figures and the
  same refusals:

    * `:terms` — a product's market at a recent block, one reading every
      visitor shares for ten seconds (`Autolaunch.Earn.SharedTerms`; public)
    * `:position` — the market at the latest block, with what a wallet of the
      acting account holds in it
    * `:prepare` — the wallet steps for a deposit or withdrawal, for a wallet of
      the acting account

  The page reads those as they are. Every agent surface (the HTTP routes, which
  the browser tools call, and the hosted MCP tools) runs `:products_answer`,
  `:quote_answer`, `:positions_answer` and `:prepare_answer`: the same reads,
  each answer shaped once (`Autolaunch.Earn.Answer`), only while the site
  offers Earn (`Autolaunch.Earn.Checks.Offered`), and the steps only once the
  site has left prelaunch read-only mode
  (`Autolaunch.CoveredCalls.Checks.LaunchesOpen`). A quote is the steps'
  preview without the calls: it reserves nothing, and both, like a position,
  are read again at the latest block on every ask. A refusal is an
  `Autolaunch.Earn.Refused` naming its reason.

  Nothing is stored: the chain is the record. The acting account comes from the
  actor the caller authenticated; a wallet named in the request is only ever
  one of that account's own (`Autolaunch.CoveredCalls.Signer`).
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Earn,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Earn
  alias Autolaunch.Earn.{Answer, Catalog, Chain, Refused, SharedTerms, States, Steps}

  # An amount far beyond any real one: the largest whole number a JSON reader
  # holds exactly, as the agent tools' schemas say (priv/earn_tools.json) and
  # the page's field reads (`Autolaunch.Earn.Amount`).
  @amount [min: 1, max: 9_007_199_254_740_991]

  # What each input of the hosted tools is, in the browser tools' words
  # (priv/earn_tools.json).
  @product "The product's id exactly as autolaunch_earn_products lists it, such as aave-usdc."
  @kind "deposit or withdraw."
  @units "The amount in the asset's smallest units (USDC has 6 decimals, so 1000000 is 1 USDC). Leave it out only to withdraw everything."
  @everything "true to withdraw the whole balance as it stands when the step lands, interest included. Only for withdraw, and never with an amount."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  actions do
    action :terms, :map do
      argument :product, :string, allow_nil?: false

      run fn %{arguments: %{product: id}}, _context ->
        with {:ok, product} <- Catalog.product(id),
             {:ok, lab} <- Catalog.lab(product),
             {:ok, terms} <- SharedTerms.read(product, lab) do
          {:ok, %{product: product, terms: terms}}
        end
        |> __MODULE__.refused()
      end
    end

    action :position, :map do
      argument :product, :string, allow_nil?: false
      argument :wallet, :string

      run fn %{arguments: arguments}, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, arguments[:wallet]),
             {:ok, product} <- Catalog.product(arguments.product),
             {:ok, lab} <- Catalog.lab(product),
             {:ok, terms, holding} <- Chain.read(product, lab, wallet) do
          {:ok, %{product: product, terms: terms, holding: holding}}
        end
        |> __MODULE__.refused()
      end
    end

    action :prepare, :map do
      argument :product, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: States.kinds()]
      argument :signer, :string
      argument :amount, :integer, constraints: @amount
      argument :everything, :boolean

      run fn %{arguments: arguments}, %{actor: actor} ->
        with {:ok, signer} <- Signer.wallet(actor, arguments[:signer]),
             {:ok, prepared} <- Steps.prepare(Map.delete(arguments, :signer), signer) do
          {:ok, Map.put(prepared, :signer, signer)}
        end
        |> __MODULE__.refused()
      end
    end

    action :products_answer, :map do
      description "Every Earn product with its terms now and its risks."

      run fn _input, context ->
        Catalog.products()
        |> Enum.map(&Earn.read_earn_terms(&1.id, Ash.Context.to_opts(context)))
        |> Answer.products()
      end
    end

    action :positions_answer, :map do
      description "What the acting account's signed-in wallet holds in each Earn product."

      run fn _input, context ->
        Catalog.products()
        |> Enum.map(&Earn.read_earn_position(&1.id, %{}, Ash.Context.to_opts(context)))
        |> Answer.positions()
      end
    end

    action :quote_answer, :map do
      description "What a deposit or withdrawal comes to for a wallet of the acting account, without its calls."

      argument :product, :string, allow_nil?: false, description: @product

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: States.kinds()],
        description: @kind

      argument :amount, :integer, constraints: @amount, description: @units
      argument :everything, :boolean, description: @everything
      argument :signer, :string, description: @signer

      run fn %{arguments: %{product: product, kind: kind} = arguments}, context ->
        product
        |> Earn.prepare_earn_steps(
          kind,
          Map.drop(arguments, [:product, :kind]),
          Ash.Context.to_opts(context)
        )
        |> Answer.quote()
      end
    end

    action :prepare_answer, :map do
      description "The wallet steps for a deposit or withdrawal, for a wallet of the acting account."

      argument :product, :string, allow_nil?: false, description: @product

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: States.kinds()],
        description: @kind

      argument :amount, :integer, constraints: @amount, description: @units
      argument :everything, :boolean, description: @everything
      argument :signer, :string, description: @signer

      run fn %{arguments: %{product: product, kind: kind} = arguments}, context ->
        product
        |> Earn.prepare_earn_steps(
          kind,
          Map.drop(arguments, [:product, :kind]),
          Ash.Context.to_opts(context)
        )
        |> Answer.prepare()
      end
    end
  end

  # Ash turns a bare `{:error, atom}` into text, so a refusal is handed over as
  # an error that keeps its atom (`Autolaunch.Earn.reason/1`).
  @doc false
  def refused({:error, reason}) when is_atom(reason),
    do: {:error, Refused.exception(reason: reason)}

  def refused(result), do: result

  policies do
    policy action([:terms, :products_answer]) do
      authorize_if always()
    end

    policy action([:position, :prepare, :quote_answer, :positions_answer, :prepare_answer]) do
      authorize_if actor_present()
    end

    # What every agent surface runs, only while the site offers Earn, and never
    # by an app connected to a person's account calling as itself: its token is
    # for its identity tools alone (`Autolaunch.Agents.Connection`). Paired, it
    # calls as its agent instead.
    policy action([:products_answer, :quote_answer, :positions_answer, :prepare_answer]) do
      forbid_unless Autolaunch.Earn.Checks.Offered
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
