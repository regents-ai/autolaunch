defmodule Autolaunch.Agents do
  @moduledoc """
  Reads the shared Regent account an agent's pairing names, without creating
  records on agent reads. A person's shared account exists on every Regent
  site from their first sign-in on any of them.

  It also holds the hosted MCP server's identity tools for an app a person
  connected to their account here (`Autolaunch.Agents.Connection`).
  """
  use Ash.Domain, otp_app: :autolaunch, extensions: [AshAi]

  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Agent, System}
  alias AutolaunchWeb.{AccountUnavailableError, AgentNotPairedError, ReadFailedError, ReadFailure}

  # The hosted MCP server's identity tools, for an app a person connected to their
  # account here, with the titles, words and hints every Regent site gives them.
  @identity Map.new(RegentMCPAgents.Tools.list(), &{&1.name, &1})

  tools do
    for name <- RegentMCPAgents.Tools.names() do
      %{title: title, description: description, annotations: hints} = @identity[name]
      name = String.to_atom(name)

      tool name, Autolaunch.Agents.Connection, name do
        title(title)
        description description

        annotations(
          read_only_hint: hints.readOnlyHint,
          idempotent_hint: hints.idempotentHint,
          destructive_hint: hints.destructiveHint,
          open_world_hint: hints.openWorldHint
        )
      end
    end
  end

  resources do
    resource Autolaunch.Agents.Connection
  end

  @doc """
  The actor a wallet the sign-in service vouches for acts as here, with the
  account its pairing names: the agent acting for its person while it is
  paired, `:not_paired` otherwise. The signed-agent routes use it
  (`AutolaunchWeb.Plugs.AgentAccess`), and so does the hosted MCP server, for
  the wallet of a connected app's own identity (`AutolaunchWeb.Plugs.McpAgent`).
  """
  def resolve(wallet) do
    with {:ok, pairing} <- RegentAgents.Authority.resolve(Repo, wallet),
         {:ok, account} <- person(pairing.privy_user_id) do
      {:ok,
       %Agent{
         wallet_address: wallet,
         privy_user_id: pairing.privy_user_id,
         pairing_id: pairing.id,
         acting_agent_id: pairing.id,
         human_account_id: account.id
       }, account}
    end
  end

  # How a check-in (`GET /api/agents/v1/me`) and an agent's status
  # (`GET /api/agents/v1/whoami`) name the person's account: their shared
  # account. A pairing that names no Regent account pairs the agent with
  # nobody, the 403 `agent_not_paired` (`AutolaunchWeb.AgentNotPairedError`);
  # an account that could not be read just now is the 503 `account_unavailable`
  # (`AutolaunchWeb.AccountUnavailableError`).
  def paired_account(privy_id) do
    case person(privy_id) do
      {:ok, account} ->
        %{
          display_name: account.display_name,
          ens_name: account.ens_name,
          wallet_address: account.wallet_address,
          wallet_addresses: account.wallet_addresses || []
        }

      # The library's contract says nil here, which its whoami answers as
      # person_not_here; Sean's one-account rule forbids that answer, so this
      # raises until RegentAgents.HTTP takes agent_not_paired for it.
      {:error, :not_paired} ->
        raise AgentNotPairedError

      {:error, :account_unavailable} ->
        raise AccountUnavailableError
    end
  end

  # The person's shared account, or `:not_paired` when the pairing names none.
  # A read that fails is logged by kind and module only and sorted as on a
  # page (`AutolaunchWeb.ReadFailure`): a lost connection is unavailable, the
  # agent's 503 try-again; anything else is the plain error, its 500.
  defp person(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, %{} = account} ->
        {:ok, account}

      {:ok, nil} ->
        {:error, :not_paired}

      {:error, error} ->
        case ReadFailure.log("agent's person read", error) do
          :connection_lost -> {:error, :account_unavailable}
          :failed -> raise ReadFailedError
        end
    end
  end
end
