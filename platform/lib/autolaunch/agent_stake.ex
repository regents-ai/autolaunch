defmodule Autolaunch.AgentStake do
  @moduledoc """
  A paired agent's wallet steps for its person's staking on a launched token,
  offered only while the site switches them on (`AUTOLAUNCH_AGENT_STAKING=true`,
  `enabled?/0`):

    * `:prepare` — one staking action's steps on a token the site lists,
      reviewed as the token page's Stake and Claim views review them
      (`Autolaunch.Stocks.StakeActions.review/2`, which the page's
      `StakeActions.prepare/3` runs too), on the chain the token runs on, Base
      or Robinhood Chain: `stake` (the wallet's whole balance of the token, with
      the token approval first when the allowance is short), `unstake` (the
      amount named) or `claim` (the steps that move waiting trading fees to the
      stakers, then the claim of everything the wallet has waiting)

  Every agent surface runs it, so each answers in one shape: the signed HTTP
  route, which the browser tool calls (`AutolaunchWeb.AgentStakeController`),
  and the hosted MCP tool. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account).

  The token is one the site lists and shows, as its page reads it, known
  before any chain is read. `amount` is taken by `unstake` alone, which needs
  it; a stake moves the wallet's whole balance, as the page's does, and a claim
  moves everything waiting, so neither takes one.

  A refusal is an `Autolaunch.AgentStake.Refused` holding one of the codes the
  agent staking contract documents: the code `code/1` gives for a reason the
  review, the listing, the wallet or the account names, or `invalid_request`
  for input the action does not take, which the route and the hosted MCP
  server refuse before it runs (`AutolaunchWeb.AgentStakeAnswer`,
  `AutolaunchWeb.ToolErrors`). Anything else the review returns or raises is
  logged by kind alone and answered `stake_unavailable`.

  The site only prepares: the wallet's own key signs and sends each step, and
  nothing is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentStake.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.ReadFailure

  # Every reason the review, the token's listing, the wallet and the person's
  # account name, as the code an agent is answered with. An id naming no token
  # the site lists and shows names no token here. An amount the review cannot
  # read, zero, or more than the staking contract can move at once is not one
  # to unstake. A chain the review could not read is `chain_unavailable`, as on
  # the token page; a staking contract the site cannot find or read for a token
  # it lists is the site's own fault, which the agent cannot mend:
  # `stake_unavailable`, logged by kind alone.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    token_not_listed: :token_not_found,
    amount_required: :invalid_amount,
    invalid_decimal: :invalid_amount,
    amount_not_representable: :invalid_amount,
    amount_too_large: :invalid_amount,
    amount_above_stake: :amount_above_stake,
    nothing_to_stake: :nothing_to_stake,
    chain_unavailable: :chain_unavailable
  }

  # What each input of the hosted tool is, in the browser tool's words
  # (priv/agent_stake_tools.json).
  @token_id "The token's id exactly as autolaunch_tokens lists it."
  @kind "stake to stake this wallet's whole balance of the token, unstake to unstake the amount named, or claim to claim everything this wallet has waiting."
  @amount "For unstake only, and needed there: how much of the token to unstake, as a decimal with at most 18 decimal places. Leave it out for stake and claim."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent staking (`AUTOLAUNCH_AGENT_STAKING=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_staking, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason the review, the
  token's listing, the wallet or the person's account names. Any other reason,
  and anything that is not a reason, is `:stake_unavailable`: a read that
  failed, or one nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :stake_unavailable

  actions do
    action :prepare, :map do
      description "One staking action's wallet steps on a token the site lists, stake, unstake or claim, for a wallet of the paired agent's person."

      argument :token_id, :uuid, allow_nil?: false, description: @token_id

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:stake, :unstake, :claim]],
        description: @kind

      # Typed figures reach the review exactly as sent, so its own refusals
      # name what is wrong with them, as on the page.
      argument :amount, :string,
        constraints: [allow_empty?: true, trim?: false],
        description: @amount

      argument :signer, :string, description: @signer

      validate present(:amount), where: [argument_equals(:kind, :unstake)]
      validate absent(:amount), where: [argument_in(:kind, [:stake, :claim])]

      run fn input, %{actor: actor} -> __MODULE__.stake_steps(input.arguments, actor) end
    end
  end

  @doc false
  def stake_steps(%{token_id: id, kind: kind} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, token} <- listed_token(id),
         {:ok, reviewed} <-
           StakeActions.review(
             %{kind: kind, launch: launch(token), amount: arguments[:amount]},
             signer
           ) do
      {:ok,
       %{
         kind: Atom.to_string(kind),
         signer: signer,
         token: %{id: token.id, address: reviewed.context.token},
         chain: reviewed.chain,
         block: reviewed.block,
         steps: reviewed.steps,
         facts: facts(reviewed)
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

  # The wallet's own position the review was read from, at `block`: its
  # balance of the token, its stake and what it can claim of each asset.
  defp facts(%{position: position, context: context}) do
    %{
      balance: %{amount: position.balance.shown, symbol: context.token_symbol},
      staked: %{amount: position.staked.shown, symbol: context.token_symbol},
      claimable: [
        %{amount: position.claimable.dollar.shown, symbol: context.dollar_symbol},
        %{amount: position.claimable.token.shown, symbol: context.token_symbol},
        %{amount: position.claimable.stock.shown, symbol: context.currency_symbol}
      ]
    }
  end

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentStakeAnswer`). The review
  # names its reasons inside Ash's own unavailable error; the listing's failed
  # read is Ash's own error. One nobody named, or a raise, which the function's
  # rescue catches as the backstop it is, is logged by kind alone
  # (`AutolaunchWeb.ReadFailure`) and answered `stake_unavailable`.
  defp refused({:ok, _answer} = answered), do: answered

  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :stake_unavailable, do: ReadFailure.log("agent stake", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent staking: off, the hosted MCP server neither lists nor runs
    # the tool, as the route and browser tool are not there either.
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
