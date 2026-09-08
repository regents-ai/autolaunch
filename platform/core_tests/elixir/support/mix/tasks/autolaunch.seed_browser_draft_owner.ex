defmodule Mix.Tasks.Autolaunch.SeedBrowserDraftOwner do
  use Mix.Task

  @shortdoc "Seeds the signed-in account the Create browser spec uses"

  @fixture_token "other-account"

  @impl Mix.Task
  def run(_args) do
    env = Mix.env()
    repo_config = Autolaunch.Repo.config()
    validate_target!(env, repo_config)

    Mix.Task.run("app.start")
    seed!()
  end

  def seed! do
    %{privy_user_id: privy_user_id, wallet_address: wallet_address} = fixture_identity!()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Autolaunch.Repo, fn ->
      Autolaunch.Accounts.register_verified!(
        privy_user_id,
        wallet_address,
        [wallet_address],
        actor: %Autolaunch.Actors.System{}
      )
    end)

    :ok
  end

  def validate_target!(env, repo_config) when is_list(repo_config) do
    database = to_string(repo_config[:database])

    if env == :test and String.ends_with?(database, "_test") do
      :ok
    else
      raise "browser Autolaunch draft owner seed refused unsafe database target"
    end
  end

  defp fixture_identity! do
    case Autolaunch.TestPrivyVerifier.verify_access_token(@fixture_token) do
      {:ok,
       %Autolaunch.VerifiedPrivyIdentity{
         privy_user_id: privy_user_id,
         wallet_address: wallet_address,
         wallet_addresses: [wallet_address]
       }}
      when is_binary(privy_user_id) and is_binary(wallet_address) ->
        %{privy_user_id: privy_user_id, wallet_address: wallet_address}

      other ->
        raise "browser Autolaunch draft owner seed fixture identity mismatch: #{inspect(other)}"
    end
  end
end
