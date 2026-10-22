defmodule Autolaunch.DatabaseConfigTest do
  use ExUnit.Case, async: true

  alias Autolaunch.DatabaseConfig

  test "Fly MPG runtime URLs use the direct endpoint with verified TLS and session limits" do
    options =
      DatabaseConfig.runtime_config!(:prod, fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_URL" ->
          "postgresql://autolaunch-runtime:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod"

        _ ->
          nil
      end)

    assert options[:socket_options] == [:inet6]
    assert options[:port] == 5432
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:cacertfile] == CAStore.file_path()
    assert options[:ssl][:server_name_indication] == ~c"direct.dzx6qo6xqzvojpv5.flympg.net"
    assert is_function(options[:ssl][:customize_hostname_check][:match_fun], 2)
    assert options[:max_lifetime] == 480_000..540_000
    assert options[:idle_interval] == 15_000
    assert options[:backoff_type] == :rand_exp
    assert options[:connect_timeout] == 5_000
    assert options[:show_sensitive_data_on_connection_error] == false

    assert options[:parameters] == [
             application_name: "autolaunch-web",
             statement_timeout: "15000",
             lock_timeout: "5000",
             idle_in_transaction_session_timeout: "15000"
           ]
  end

  test "the serving boot connects with the serving login when the app also holds the release login" do
    serving =
      "postgresql://autolaunch-runtime:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod"

    options =
      DatabaseConfig.runtime_config!(:prod, fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_URL" ->
          serving

        "DATABASE_DIRECT_URL" ->
          "postgresql://migrator:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod"

        _ ->
          nil
      end)

    assert options[:url] == serving
  end

  test "Fly MPG direct migration URLs use verified TLS" do
    options =
      DatabaseConfig.release_config!(fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_DIRECT_URL" ->
          "postgresql://migrator:password@direct.cluster.flympg.net/regents_prod"
      end)

    refute Keyword.has_key?(options, :max_lifetime)
    refute Keyword.has_key?(options, :parameters)
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:server_name_indication] == ~c"direct.cluster.flympg.net"
  end
end
