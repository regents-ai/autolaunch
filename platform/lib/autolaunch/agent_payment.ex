defmodule Autolaunch.AgentPayment do
  @moduledoc """
  A paired agent's wallet steps for its person's payment into a launched
  token's revenue split, offered only while the site switches them on
  (`AUTOLAUNCH_AGENT_PAYMENTS=true`, `enabled?/0`):

    * `:prepare` — one action of the token page's Make a payment card on a
      Revstake token the site lists, reviewed as the card reviews it
      (`Autolaunch.SubjectWalletActions.review/4`, which the card's
      `SubjectWalletActions.prepare/5` runs too), on Base: `pay` pays
      `amount` of the asset named into the token's revenue split, with an
      exact approval to its payment address first when the allowance is
      short; `sweep` routes the whole balance of the asset already waiting at
      that payment address into the split, and takes no amount

  Every agent surface runs it, so each answers in one shape: the signed HTTP
  route, which the browser tool calls (`AutolaunchWeb.AgentPaymentController`),
  and the hosted MCP tool. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account).

  The token is one the site lists and shows, as its page reads it, known
  before any chain is read; a site on the local Base fork shows no payment
  card, so it offers no agent payment either. The asset is USDC, REGENT or the
  token itself (`token`).

  A refusal is an `Autolaunch.AgentPayment.Refused` holding one of the codes
  the agent payments contract documents: the code `code/1` gives for a reason
  the review, the listing, the wallet or the account names, or
  `invalid_request` for input the action does not take, which the route and
  the hosted MCP server refuse before it runs (`AutolaunchWeb.AgentPaymentAnswer`,
  `AutolaunchWeb.ToolErrors`). Anything else the review returns or raises is
  logged by kind alone and answered `payment_unavailable`.

  The site only prepares: the wallet's own key signs and sends each step, and
  nothing is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentPayment.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.{Lab, SubjectWalletActions, Token}
  alias AutolaunchWeb.ReadFailure

  # Every reason the review, the token's listing, the wallet and the person's
  # account name, as the code an agent is answered with. An id naming no token
  # the site lists and shows names no token here. A token that is not a
  # Revstake one, or not on this site's network, takes no payment here; one
  # whose token, revenue split, treasury or payment address the launch has not
  # named yet takes none yet. A revenue split or payment address the chain
  # says is not the launch's own is refused, as on the page, before anything
  # could reach it. A chain the review could not read is `chain_unavailable`;
  # a launch the site cannot read, or a Base deployment on another network
  # than the launch's (`review_network_mismatch`), is the site's own fault,
  # which the agent cannot mend: `payment_unavailable`, logged by kind alone.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    token_not_listed: :token_not_found,
    invalid_amount: :invalid_amount,
    test_chain: :payment_not_offered,
    subject_not_found: :payment_not_offered,
    subject_not_on_base: :payment_not_offered,
    subject_token_unavailable: :payment_not_open,
    subject_splitter_unavailable: :payment_not_open,
    subject_treasury_unavailable: :payment_not_open,
    canonical_receiver_unavailable: :payment_not_open,
    splitter_subject_mismatch: :split_mismatch,
    splitter_usdc_mismatch: :split_mismatch,
    splitter_regent_mismatch: :split_mismatch,
    splitter_treasury_mismatch: :split_mismatch,
    receiver_splitter_mismatch: :split_mismatch,
    receiver_subject_mismatch: :split_mismatch,
    receiver_usdc_mismatch: :split_mismatch,
    receiver_regent_mismatch: :split_mismatch,
    receiver_treasury_mismatch: :split_mismatch,
    receiver_not_canonical: :split_mismatch,
    amount_above_balance: :amount_above_balance,
    nothing_to_sweep: :nothing_to_sweep,
    chain_unavailable: :chain_unavailable
  }

  # The card's own name for each asset (`AutolaunchWeb.SubjectWalletComponent`).
  @assets %{usdc: "usdc", regent: "regent", token: "subject"}

  # What each input of the hosted tool is, in the browser tool's words
  # (priv/agent_payment_tools.json).
  @token_id "The token's id exactly as autolaunch_tokens lists it."
  @kind "pay to pay the amount named into the token's revenue split, or sweep to route everything of the asset already waiting at its payment address into the split."
  @asset "usdc for USDC, regent for REGENT, or token for the token itself."
  @amount "For pay only, and needed there: how much of the asset to pay, as a decimal with no more decimal places than the asset has. Leave it out for sweep."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent payments (`AUTOLAUNCH_AGENT_PAYMENTS=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_payments, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason the review, the
  token's listing, the wallet or the person's account names. Any other reason,
  and anything that is not a reason, is `:payment_unavailable`: a read that
  failed, or one nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :payment_unavailable

  actions do
    action :prepare, :map do
      description "One payment into, or sweep into, a listed token's revenue split, for a wallet of the paired agent's person."

      argument :token_id, :uuid, allow_nil?: false, description: @token_id

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pay, :sweep]],
        description: @kind

      argument :asset, :atom,
        allow_nil?: false,
        constraints: [one_of: [:usdc, :regent, :token]],
        description: @asset

      # Typed figures reach the review exactly as sent, so its own refusals
      # name what is wrong with them, as on the page.
      argument :amount, :string,
        constraints: [allow_empty?: true, trim?: false, max_length: 128],
        description: @amount

      argument :signer, :string, constraints: [max_length: 128], description: @signer

      validate present(:amount), where: [argument_equals(:kind, :pay)]
      validate absent(:amount), where: [argument_equals(:kind, :sweep)]

      run fn input, %{actor: actor} -> __MODULE__.payment_steps(input.arguments, actor) end
    end
  end

  @doc false
  def payment_steps(%{token_id: id, kind: kind, asset: asset} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, token} <- Token.listed(id),
         :ok <- offered_here(),
         {:ok, reviewed} <-
           SubjectWalletActions.review(token.auction.id, signer, kind, %{
             "asset" => Map.fetch!(@assets, asset),
             "amount" => arguments[:amount]
           }) do
      {:ok,
       %{
         kind: Atom.to_string(kind),
         asset: Atom.to_string(asset),
         signer: signer,
         token: %{id: token.id, address: reviewed.subject},
         chain: reviewed.chain,
         steps: reviewed.steps,
         facts: facts(reviewed.facts, symbol(asset, token))
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  # The token page shows no payment card on a site reading the local Base fork.
  defp offered_here, do: if(Lab.test_chain?(), do: {:error, :test_chain}, else: :ok)

  defp symbol(:token, token), do: Token.presentation(token).symbol
  defp symbol(:usdc, _token), do: "USDC"
  defp symbol(:regent, _token), do: "REGENT"

  # The figures the card shows beside the steps: what the wallet pays, or what
  # the sweep routes, and how that divides as staking stands now: the
  # protocol's 2%, then the stakers' part and the treasury's. Also where it is
  # paid and the reference its payment carries.
  defp facts(%{asset: asset, allocation: allocation} = facts, symbol) do
    shown = &%{amount: SubjectWalletActions.units(&1, asset), symbol: symbol}

    %{
      amount: %{amount: facts.amount, symbol: symbol},
      receiver: facts.receiver,
      payment_reference: facts.payment_reference,
      split: %{
        protocol: shown.(allocation.skim),
        stakers: shown.(allocation.stakers),
        treasury: shown.(allocation.treasury)
      }
    }
  end

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentPaymentAnswer`). The review
  # names its reasons inside Ash's own unavailable error; the listing's failed
  # read is Ash's own error. One nobody named, or a raise, which the function's
  # rescue catches (Ash raises a raise in an action's `run` again rather than
  # returning it, so the route would crash), is logged by kind alone
  # (`AutolaunchWeb.ReadFailure`) and answered `payment_unavailable`.
  defp refused({:ok, _answer} = answered), do: answered

  defp refused({:error, %Ash.Error.Invalid.Unavailable{reason: reason}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :payment_unavailable, do: ReadFailure.log("agent payment", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent payments: off, the hosted MCP server neither lists nor runs
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
