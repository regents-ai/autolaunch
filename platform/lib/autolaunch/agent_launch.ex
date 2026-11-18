defmodule Autolaunch.AgentLaunch do
  @moduledoc """
  A paired agent's launch step for its person's saved draft, offered only
  while the site switches it on (`AUTOLAUNCH_AGENT_LAUNCHES=true`,
  `enabled?/0`):

    * `:prepare` — the one `launch` step of the person's Revstake or Memestock
      draft, reviewed as the create page reviews it: a Revstake draft on Base
      (`Autolaunch.LaunchActions.review/2`), a Memestock draft on the chain it
      names, Base (`Autolaunch.Stocks.LaunchActions.review/2`) or Robinhood
      Chain (`Autolaunch.Robinhood.StocksLaunchActions.review/2`)

  Every agent surface runs it, so each answers in one shape: the signed HTTP
  route, which the browser tool calls (`AutolaunchWeb.AgentLaunchController`),
  and the hosted MCP tool. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account). The draft is the person's own, read through the agent's own
  draft read, so another person's draft is named nowhere and refused before any
  chain is read. The signer is proved before any chain is read; the write that
  keeps the review proves again only the pairing (`RegentAgents.RequirePairing`).

  A draft's treasury may be any wallet. What only the person can give stays
  on the create page: the acknowledgement a treasury held by a private key
  takes, the confirmation of a Safe or smart contract account the agent chose,
  and a Safe's verification. Until then the draft is refused with the reason
  the create page names.

  Every answer carries `warnings`, what the agent tells its person before they
  sign, none of which holds the step back: empty, or for a Revstake draft whose
  person has no X, GitHub or ENS account on show (`Autolaunch.Accounts.connected?/1`)
  `no_connections`, the warning the create page has the person type before
  such a launch.

  A refusal is an `Autolaunch.AgentLaunch.Refused` holding one of the codes the
  agent launch contract documents (`code/1`). A pairing that ended or changed
  hands while the request ran is `agent_not_paired`, as on every signed route.
  Anything else the review returns or raises that is not a reason it names,
  any other refusal included, is logged by kind alone and answered
  `launch_unavailable`.

  The site only prepares: the wallet's own key signs and sends the step. The
  review is kept as the create page keeps its own (`Autolaunch.LaunchOperation`,
  `Autolaunch.Stocks.LaunchOperation`, `Autolaunch.Robinhood.LaunchReview`), for
  the person the pairing names and marked as the agent's (`prepared_by`), so the
  launch is listed as this site's once the chain shows it, from the person's own
  review when there is one. Each preparation stays good for 24 hours, and at
  most 20 unused ones are kept; past that, a different one waits for the
  oldest to turn 24 hours old (`Autolaunch.AgentLaunch.Preparations`).
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias Ash.Error.Changes.InvalidChanges
  alias Ash.Error.Invalid.Unavailable
  alias Autolaunch.{Accounts, LaunchActions, LaunchDraft, LaunchOperation}
  alias Autolaunch.AgentLaunch.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Robinhood.LaunchReview
  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions
  alias Autolaunch.Stocks.LaunchDraft, as: StocksDraft
  alias Autolaunch.Stocks.LaunchOperation, as: StocksLaunchOperation
  alias AutolaunchWeb.ReadFailure

  # Every reason the three reviews, the wallet, the person's account and the
  # agent's pairing name, as the code an agent is answered with. A refusal the
  # create page names keeps its own name. A treasury that is not verified has
  # no report yet; one whose verified state or evidence no longer holds was
  # changed. A stock the draft names that the chain does not list is not one a
  # launch can pair with. A chain answering what is not a block of it, part of
  # an answer, or nothing, could not be read just now. Twenty unused
  # preparations none of which is 24 hours old leave no room for another
  # (`Autolaunch.AgentLaunch.Preparations`). A deployment description that does
  # not load or no longer matches the chain, and a draft or review the site
  # could not read or keep, are the site's own fault.
  @codes %{
    authentication_required: :authentication_required,
    agent_not_paired: :agent_not_paired,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    launch_draft_not_found: :launch_draft_not_found,
    launch_metadata_incomplete: :launch_metadata_incomplete,
    agent_treasury_unconfirmed: :agent_treasury_unconfirmed,
    launch_treasury_invalid: :launch_treasury_invalid,
    launch_treasury_refused: :launch_treasury_refused,
    launches_paused: :launches_paused,
    strategy_not_bound: :strategy_not_bound,
    treasury_report_missing: :treasury_report_missing,
    treasury_not_verified: :treasury_report_missing,
    treasury_security_changed: :treasury_security_changed,
    treasury_source_reorged: :treasury_security_changed,
    treasury_safe_evidence_mismatch: :treasury_security_changed,
    treasury_evidence_invalid: :treasury_security_changed,
    treasury_evidence_hash_invalid: :treasury_security_changed,
    treasury_transfer_evidence_invalid: :treasury_security_changed,
    treasury_execution_evidence_invalid: :treasury_security_changed,
    treasury_execution_input_invalid: :treasury_security_changed,
    treasury_module_pagination_cycle: :treasury_security_changed,
    treasury_configuration_drift: :treasury_configuration_drift,
    stock_invalid: :stock_invalid,
    unsupported_stock: :stock_invalid,
    invalid_address: :stock_invalid,
    stock_not_admitted: :stock_not_admitted,
    stocks_unavailable: :stocks_unavailable,
    robinhood_unavailable: :robinhood_unavailable,
    chain_unavailable: :chain_unavailable,
    invalid_chain_response: :chain_unavailable,
    invalid_block_header: :chain_unavailable,
    transaction_missing: :chain_unavailable,
    wrong_chain: :chain_unavailable,
    launch_snapshot_incomplete: :chain_unavailable,
    treasury_observation_incomplete: :chain_unavailable,
    treasury_module_pagination_incomplete: :chain_unavailable,
    too_many_preparations: :too_many_preparations
  }

  # What each input of the hosted tool is, in the browser tool's words
  # (priv/agent_launches_tools.json).
  @draft "The draft's id exactly as autolaunch_revstake_draft or autolaunch_memestock_draft gives it (id)."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @no_connections %{
    code: "no_connections",
    message:
      "This Revstake auction may not appear in the gallery or list, because its creator, your person, has linked no X, GitHub or ENS account; they can link one under Socials on the create page."
  }

  @doc "Whether the site offers agent launches (`AUTOLAUNCH_AGENT_LAUNCHES=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_launches, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason any of the three
  reviews, the wallet, the person's account or the agent's pairing names. The
  pairing names two: the agent's own read or write refused by its pairing check
  (`RegentAgents.Checks.Paired`), and the write finding the pairing gone as it
  locks it (`RegentAgents.RequirePairing`), each `:agent_not_paired`. Any other
  reason, and anything that is not a reason, is `:launch_unavailable`: a
  deployment description that does not load or no longer matches the chain, a
  draft that could not be read, a review that could not be kept, a refusal that
  is not the pairing's, such as one in the steps the site runs itself, or a
  failure nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)

  def code(%Ash.Error.Forbidden{errors: [_ | _] = errors}),
    do: if(Enum.all?(errors, &unpaired?/1), do: :agent_not_paired, else: :launch_unavailable)

  def code(%Ash.Error.Invalid{errors: [%InvalidChanges{message: "active pairing required"}]}),
    do: :agent_not_paired

  def code(_unexpected), do: :launch_unavailable

  defp unpaired?(%Ash.Error.Forbidden.Policy{facts: facts}),
    do: Enum.any?(facts, &match?({{RegentAgents.Checks.Paired, _opts}, false}, &1))

  defp unpaired?(_refusal), do: false

  actions do
    action :prepare, :map do
      description "The launch step of the paired agent's person's saved draft, for a wallet of theirs."

      argument :draft, :uuid, allow_nil?: false, description: @draft
      argument :signer, :string, description: @signer

      run fn input, %{actor: actor} -> __MODULE__.launch_steps(input.arguments, actor) end
    end
  end

  @doc false
  def launch_steps(%{draft: id} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, draft} <- own_draft(id, actor),
         {:ok, prepared} <- prepare(draft, signer, actor) do
      {:ok,
       %{
         kind: "launch",
         signer: signer,
         draft: %{id: draft.id, kind: kind(draft)},
         chain: prepared.chain,
         block: prepared.facts["block_number"],
         steps: prepared.steps,
         facts: prepared.facts,
         warnings: warnings(draft, account)
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  # The person's draft of either kind, with its picture, through the agent's
  # own read: a draft of anyone else is none at all.
  defp own_draft(id, actor) do
    with {:ok, nil} <- agent_draft(LaunchDraft, :launch_draft_image, id, actor),
         {:ok, nil} <- agent_draft(StocksDraft, :stock_launch_draft_image, id, actor),
         do: {:error, :launch_draft_not_found}
  end

  defp agent_draft(resource, image, id, actor) do
    resource
    |> Ash.Query.for_read(:agent_read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(image)
    |> Ash.read_one()
  end

  # The create page's own review of the draft, kept as the page keeps it.
  defp prepare(%LaunchDraft{} = draft, signer, actor) do
    with {:ok, review} <- LaunchActions.review(draft, signer),
         {:ok, operation} <-
           keep(LaunchOperation, :agent_prepare, operation(draft, signer, review), actor),
         do: {:ok, LaunchActions.reviewed(operation)}
  end

  defp prepare(%StocksDraft{chain: :base} = draft, signer, actor) do
    with {:ok, review} <- StocksLaunchActions.review(draft, signer),
         {:ok, operation} <-
           keep(StocksLaunchOperation, :agent_prepare, operation(draft, signer, review), actor),
         do: {:ok, StocksLaunchActions.reviewed(operation)}
  end

  defp prepare(%StocksDraft{chain: :robinhood} = draft, signer, actor) do
    with {:ok, review} <- RobinhoodLaunchActions.review(draft, signer),
         {:ok, _kept} <-
           keep(LaunchReview, :agent_record, RobinhoodLaunchActions.kept(review), actor),
         do: {:ok, review}
  end

  defp operation(draft, signer, review) do
    %{
      action_id: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower),
      launch_draft_id: draft.id,
      review: review,
      signer: signer,
      step: :launch
    }
  end

  defp keep(resource, action, input, actor) do
    resource
    |> Ash.Changeset.for_create(action, input, actor: actor)
    |> Ash.create()
  end

  defp kind(%LaunchDraft{}), do: "revstake"
  defp kind(%StocksDraft{}), do: "memestock"

  # What the agent tells its person before they sign; none of it stops the
  # launch. A Revstake auction whose creator has no account on show may not
  # appear in the gallery or list, which the create page has the person type
  # before such a launch.
  defp warnings(%LaunchDraft{}, account),
    do: if(Accounts.connected?(account.id), do: [], else: [@no_connections])

  defp warnings(%StocksDraft{}, _account), do: []

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentLaunchAnswer`), as a write
  # does with the reason its own change named. One nobody named, or a raise, is
  # logged by kind alone (`AutolaunchWeb.ReadFailure`).
  defp refused({:ok, _answer} = answered), do: answered
  defp refused({:error, %Unavailable{reason: reason}}), do: refused({:error, reason})

  defp refused({:error, %Ash.Error.Invalid{errors: [%Unavailable{reason: reason}]}}),
    do: refused({:error, reason})

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :launch_unavailable, do: ReadFailure.log("agent launch", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent launches: off, the hosted MCP server neither lists nor runs
    # the tool, as the route and browser tool are not there either.
    policy always() do
      forbid_unless Autolaunch.AgentLaunch.Checks.Offered
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # The launch step waits for the site to leave prelaunch read-only mode, as
    # the HTTP route does (`AutolaunchWeb.Prelaunch`).
    policy always() do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
