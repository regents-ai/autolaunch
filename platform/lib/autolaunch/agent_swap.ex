defmodule Autolaunch.AgentSwap do
  @moduledoc """
  A paired agent's wallet steps for its person's buy or sell of a launched
  token, offered only while the site switches them on
  (`AUTOLAUNCH_AGENT_SWAPS=true`, `enabled?/0`):

    * `:prepare` — one exact-input trade on a token the site lists, reviewed
      as the token page's swap panel reviews it
      (`Autolaunch.SwapActions.review/2`, which the panel's
      `SwapActions.prepare/3` runs too), on the pool the token trades in, on
      Base or Robinhood Chain: `buy` spends `amount` of the pool's currency
      for the token, `sell` spends `amount` of the token for the currency,
      each with the token approval to Permit2 and the Permit2 allowance to
      the router first when the wallet lacks them, then the swap

  Every agent surface runs it, so each answers in one shape: the signed HTTP
  route, which the browser tool calls (`AutolaunchWeb.AgentSwapController`),
  and the hosted MCP tool. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account).

  The token is one the site lists and shows, as its page reads it, known
  before any chain is read. `protection` is the price protection in percent,
  from 1 to 10, the panel's own starting setting when left out
  (`SwapActions.default_protection/0`).

  A refusal is an `Autolaunch.AgentSwap.Refused` holding one of the codes the
  agent swaps contract documents: the code `code/1` gives for a reason the
  review, the listing, the wallet or the account names, or `invalid_request`
  for input the action does not take, which the route and the hosted MCP
  server refuse before it runs (`AutolaunchWeb.AgentSwapAnswer`,
  `AutolaunchWeb.ToolErrors`). Anything else the review returns or raises is
  logged by kind alone and answered `swap_unavailable`.

  The site only prepares: the wallet's own key signs and sends each step, and
  nothing is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentSwap.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.SwapActions
  alias AutolaunchWeb.ReadFailure

  # Every reason the review, the token's listing, the wallet and the person's
  # account name, as the code an agent is answered with. An id naming no token
  # the site lists and shows names no token here. An amount the review cannot
  # read, zero, finer than the side it spends or more than the pool takes at
  # once is not one to trade. A pool that cannot fill the amount now, and a
  # wallet holding less than it, are the review's own refusals, as on the
  # page. A chain the review could not read, or whose answer it could not
  # decode, is `chain_unavailable`; a pool or router the site cannot find or
  # read for a token it lists is the site's own fault, which the agent cannot
  # mend: `swap_unavailable`, logged by kind alone.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    token_not_listed: :token_not_found,
    amount_required: :invalid_amount,
    invalid_decimal: :invalid_amount,
    amount_not_representable: :invalid_amount,
    amount_too_large: :invalid_amount,
    protection_out_of_range: :protection_out_of_range,
    amount_above_balance: :amount_above_balance,
    quote_unavailable: :quote_unavailable,
    chain_unavailable: :chain_unavailable,
    invalid_chain_response: :chain_unavailable
  }

  # What each input of the hosted tool is, in the browser tool's words
  # (priv/agent_swap_tools.json).
  @token_id "The token's id exactly as autolaunch_tokens lists it."
  @direction "buy to spend the pool's currency on the token, or sell to spend the token for the pool's currency."
  @amount "How much this wallet spends, as a decimal: of the pool's currency for buy, of the token for sell."
  @protection "Price protection in percent, a number from 1 to 10: how far below today's quote the trade may settle. Omit it for 6."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  # Typed figures reach the review exactly as sent, so its own refusals name
  # what is wrong with them, as on the page.
  @typed [allow_empty?: true, trim?: false, max_length: 128]

  @doc "Whether the site offers agent swaps (`AUTOLAUNCH_AGENT_SWAPS=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_swaps, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason the review, the
  token's listing, the wallet or the person's account names. Any other reason,
  and anything that is not a reason, is `:swap_unavailable`: a read that
  failed, or one nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :swap_unavailable

  actions do
    action :prepare, :map do
      description "One buy or sell of a token the site lists, for a wallet of the paired agent's person."

      argument :token_id, :uuid, allow_nil?: false, description: @token_id

      argument :direction, :atom,
        allow_nil?: false,
        constraints: [one_of: [:buy, :sell]],
        description: @direction

      argument :amount, :string, allow_nil?: false, constraints: @typed, description: @amount
      argument :protection, :string, constraints: @typed, description: @protection
      argument :signer, :string, constraints: [max_length: 128], description: @signer

      run fn input, %{actor: actor} -> __MODULE__.swap_steps(input.arguments, actor) end
    end
  end

  @doc false
  def swap_steps(%{token_id: id, direction: direction, amount: amount} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, token} <- listed_token(id),
         {:ok, reviewed} <-
           SwapActions.review(
             %{
               launch: launch(token),
               direction: direction,
               amount: amount,
               protection: arguments[:protection] || SwapActions.default_protection()
             },
             signer
           ) do
      {:ok,
       %{
         direction: Atom.to_string(direction),
         signer: signer,
         token: %{id: token.id, address: reviewed.context.token},
         chain: reviewed.chain,
         block: reviewed.block,
         expires_at: DateTime.from_unix!(reviewed.expires_at),
         steps: reviewed.steps,
         facts: facts(reviewed.facts)
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  # A token the site lists and shows, as its page reads it; an id naming any
  # other names none here.
  defp listed_token(id) do
    case Autolaunch.get_listed_token(id, actor: nil) do
      {:ok, %Autolaunch.Token{} = token} -> {:ok, token}
      {:ok, nil} -> {:error, :token_not_listed}
      {:error, error} -> {:error, error}
    end
  end

  # The launch as its token page names it, on the chain its auction ran on.
  defp launch(%{auction: auction}) do
    chain = if RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base
    %{chain: chain, auction: auction}
  end

  # The figures the panel shows beside the steps: what the wallet pays, what
  # today's quote says it receives, the least the trade accepts, the price
  # protection applied and the fees already inside the quote.
  defp facts(facts) do
    %{
      pay: %{amount: facts.pay, symbol: facts.sell_symbol},
      receive: %{amount: facts.receive, symbol: facts.buy_symbol},
      minimum: %{amount: facts.minimum, symbol: facts.buy_symbol},
      protection: facts.protection,
      fees: facts.fees
    }
  end

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentSwapAnswer`). The review
  # names its reasons inside Ash's own unavailable error; the listing's failed
  # read is Ash's own error. One nobody named, or a raise, which the function's
  # rescue catches as the backstop it is, is logged by kind alone
  # (`AutolaunchWeb.ReadFailure`) and answered `swap_unavailable`.
  defp refused({:ok, _answer} = answered), do: answered

  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :swap_unavailable, do: ReadFailure.log("agent swap", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent swaps: off, the hosted MCP server neither lists nor runs the
    # tool, as the route and browser tool are not there either.
    policy always() do
      forbid_unless {Autolaunch.Checks.Offered, feature: __MODULE__}
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # Wallet steps wait for the site to leave prelaunch read-only mode, as the
    # HTTP route does (`AutolaunchWeb.Prelaunch`).
    policy always() do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
