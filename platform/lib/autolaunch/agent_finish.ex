defmodule Autolaunch.AgentFinish do
  @moduledoc """
  A paired agent's wallet step for finishing an ended auction, offered only
  while the site switches it on (`AUTOLAUNCH_AGENT_FINISH=true`,
  `enabled?/0`):

    * `:prepare` — the one `finish` step of an auction the site lists, read as
      the auction page's Finish button reads it (`Autolaunch.FinishActions.read/1`),
      on the chain the auction runs on, Base or Robinhood Chain

  Every agent surface runs it, so each answers in one shape: the signed HTTP
  route, which the browser tool calls (`AutolaunchWeb.AgentFinishController`),
  and the hosted MCP tool. The person must have a verified wallet now, as
  `autolaunch_my_positions` asks, and the wallet is one of the person's own,
  `signer` when named, otherwise the wallet they signed in with
  (`Autolaunch.CoveredCalls.Signer.verified/1` and `wallet/2`, from one read of
  the account). Anyone may finish an auction, so any of the person's wallets
  may send it; the network fee is all it costs.

  The auction is one the site lists and shows, as its page reads it, known
  before any chain is read. The page and the agent follow one rule
  (`FinishActions.read/1`'s `blocked`): read at the latest block, a finish that
  would revert if sent at the launchpad clock's next step is refused, as
  `finish_not_open`, naming the block finishing opens at, while that step is
  before the launch's migration block, and as `auction_finished` once the
  launch is finished.

  A refusal is an `Autolaunch.AgentFinish.Refused` holding one of the codes the
  agent finish contract documents: the code `code/1` gives for a reason the
  read, the listing, the wallet or the account names; `finish_not_open`, with
  the block finishing opens at, for a launch whose migration block is still
  ahead; or `invalid_request` for input the action does not take, which the
  route and the hosted MCP server refuse before it runs
  (`AutolaunchWeb.AgentFinishAnswer`, `AutolaunchWeb.ToolErrors`). Anything
  else the read returns or raises is logged by kind alone and answered
  `finish_unavailable`.

  The site only prepares: the wallet's own key signs and sends the step, and
  nothing is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.AgentFinish.Refused
  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.FinishActions
  alias AutolaunchWeb.ReadFailure

  # Every reason the read, the auction's listing, the wallet and the person's
  # account name, as the code an agent is answered with. An id naming no
  # auction the site lists and shows names no auction here. A finish on a
  # launch already finished is `auction_finished`; one while its migration
  # block is still ahead is refused with that block (`open/1`). A chain the
  # read could not read, or a launchpad no deployment description names, is
  # `chain_unavailable`, as on the auction page. A launchpad that holds no
  # launch for an auction the site lists is the site's own fault, which the
  # agent cannot mend: `finish_unavailable`, logged by kind alone.
  @codes %{
    authentication_required: :authentication_required,
    wallet_required: :wallet_required,
    wrong_signer: :wrong_signer,
    auction_not_listed: :auction_not_found,
    auction_finished: :auction_finished,
    chain_unavailable: :chain_unavailable,
    launch_not_found: :finish_unavailable
  }

  # What each input of the hosted tool is, in the browser tool's words
  # (priv/agent_finish_tools.json).
  @auction_id "The auction's id exactly as autolaunch_auctions lists it."
  @signer "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."

  @doc "Whether the site offers agent finishes (`AUTOLAUNCH_AGENT_FINISH=true`, config/runtime.exs)."
  def enabled?, do: Application.get_env(:autolaunch, :agent_finish, :off) == :on

  @doc """
  The code an agent is answered with for `reason`, a reason the read, the
  auction's listing, the wallet or the person's account names. Any other
  reason, and anything that is not a reason, is `:finish_unavailable`: a read
  that failed, or one nobody expected.
  """
  def code(reason) when is_map_key(@codes, reason), do: Map.fetch!(@codes, reason)
  def code(_unexpected), do: :finish_unavailable

  actions do
    action :prepare, :map do
      description "The finish step of an ended auction the site lists, for a wallet of the paired agent's person."

      argument :auction_id, :uuid, allow_nil?: false, description: @auction_id
      argument :signer, :string, description: @signer

      run fn input, %{actor: actor} -> __MODULE__.finish_steps(input.arguments, actor) end
    end
  end

  @doc false
  def finish_steps(%{auction_id: id} = arguments, actor) do
    with {:ok, account} <- Signer.verified(actor),
         {:ok, signer} <- Signer.wallet(account, arguments[:signer]),
         {:ok, auction} <- listed_auction(id),
         {:ok, launch} <- FinishActions.read(auction),
         :ok <- open(launch) do
      {:ok,
       %{
         kind: "finish",
         signer: signer,
         auction: %{id: auction.id, address: auction.auction_address},
         chain: launch.chain,
         block: launch.block,
         steps: launch.steps,
         facts: %{migration_block: launch.migration_block, clock: launch.clock}
       }}
    end
    |> refused()
  rescue
    failure -> refused({:error, failure})
  end

  # An auction the site lists and shows, as its page reads it; an id naming any
  # other names none here.
  defp listed_auction(id) do
    case Autolaunch.get_listed_auction(id, actor: nil) do
      {:ok, %Autolaunch.Auction{} = auction} -> {:ok, auction}
      {:ok, nil} -> {:error, :auction_not_listed}
      {:error, error} -> {:error, error}
    end
  end

  # The launch as the read finds it: one whose finish would not revert if sent
  # at the clock's next step is prepared. Before its migration block, the
  # refusal names the block finishing opens at.
  defp open(%{blocked: nil}), do: :ok

  defp open(%{blocked: :finish_not_open, migration_block: opens_at}),
    do: {:error, Refused.exception(reason: :finish_not_open, opens_at: opens_at)}

  defp open(%{blocked: :auction_finished}), do: {:error, :auction_finished}

  # A refusal holds the code of the reason it names (`code/1`), which Ash would
  # otherwise turn into text (`AutolaunchWeb.AgentFinishAnswer`). Every step
  # but the listing names its reason as an atom; the listing's failed read is
  # Ash's own error. One nobody named, or a raise, which the function's rescue
  # catches as the backstop it is, is logged by kind alone
  # (`AutolaunchWeb.ReadFailure`) and answered `finish_unavailable`, as a
  # reason that maps there is (`code/1`).
  defp refused({:ok, _answer} = answered), do: answered
  defp refused({:error, %Refused{}} = refusal), do: refusal

  defp refused({:error, reason}) do
    code = code(reason)
    if code == :finish_unavailable, do: ReadFailure.log("agent finish", reason)
    {:error, Refused.exception(reason: code)}
  end

  policies do
    # Only a paired agent, for the person it acts for, and only while the site
    # offers agent finishes: off, the hosted MCP server neither lists nor runs
    # the tool, as the route and browser tool are not there either.
    policy always() do
      forbid_unless Autolaunch.AgentFinish.Checks.Offered
      authorize_if actor_attribute_equals(:role, :agent)
    end

    # The finish step waits for the site to leave prelaunch read-only mode, as
    # the HTTP route does (`AutolaunchWeb.Prelaunch`).
    policy always() do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
