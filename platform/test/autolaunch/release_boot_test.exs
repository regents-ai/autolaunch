defmodule Autolaunch.ReleaseBootTest do
  @moduledoc """
  The deploy runs the migrations on a temporary machine of the serving app
  (fly.toml `release_command`), so that boot sees the serving app's settings,
  the deployment description paths included, while fly.toml's files may not be
  on it. The migration boot reads no deployment description and takes the
  release login.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @release_login "postgresql://migrator:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod"

  # fly.toml's [env] for autolaunch-sh, the secrets both logins need, and the
  # migration command's own switch. The descriptions are not on this machine.
  @release_machine %{
    "AUTOLAUNCH_RELEASE_COMMAND" => "migrate",
    "AUTOLAUNCH_DEPLOYMENT_ROLE" => "production",
    "AUTOLAUNCH_BASE_DEPLOYMENT" => "/app/deployment/base-revstake.json",
    "AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT" => "/app/deployment/base-memestock.json",
    "AUTOLAUNCH_BASE_DEPLOYMENT_ID" => "base-mainnet",
    "AUTOLAUNCH_ROBINHOOD_DEPLOYMENT" => "/app/deployment/robinhood.json",
    "AUTOLAUNCH_LAUNCHES_OPEN" => "true",
    "DATABASE_URL" =>
      "postgresql://autolaunch-runtime:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod",
    "DATABASE_DIRECT_URL" => @release_login
  }

  setup do
    saved = Map.new(@release_machine, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(@release_machine)
  end

  test "RELEASE_BOOT_READS_NO_DESCRIPTION: the migration boot on the serving app reads no deployment description and takes the release login" do
    config = Config.Reader.read!(@runtime, env: :prod, target: :host)

    refute Keyword.has_key?(config[:autolaunch], :autolaunch_base_deployment)
    refute Keyword.has_key?(config[:autolaunch], :autolaunch_robinhood_deployment)
    assert config[:autolaunch][Autolaunch.Repo][:url] == @release_login
  end
end
