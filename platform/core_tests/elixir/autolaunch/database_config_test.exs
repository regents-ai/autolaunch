defmodule Autolaunch.DatabaseConfigTest do
  use ExUnit.Case, async: true

  alias Autolaunch.DatabaseConfig

  test "Fly MPG runtime URLs require verified TLS and unnamed pooler prepares" do
    options =
      DatabaseConfig.runtime_config!(:prod, fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "staging"

        "DATABASE_URL" ->
          "postgresql://runtime:***@pgbouncer.cluster.flympg.net/regents_prod"

        _ ->
          nil
      end)

    assert options[:prepare] == :unnamed
    assert options[:socket_options] == [:inet6]
    assert options[:port] == 5432
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:cacertfile] == "/etc/ssl/certs/ca-certificates.crt"
    assert options[:ssl][:server_name_indication] == ~c"pgbouncer.cluster.flympg.net"
    assert is_function(options[:ssl][:customize_hostname_check][:match_fun], 2)
    assert options[:max_lifetime] == 480_000..540_000
    assert options[:idle_interval] == 15_000
    assert options[:backoff_type] == :rand_exp
    assert options[:connect_timeout] == 5_000
    assert options[:show_sensitive_data_on_connection_error] == false
    assert options[:parameters] == [application_name: "autolaunch-web"]

    direct =
      DatabaseConfig.runtime_config!(:prod, fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_URL" ->
          "postgresql://autolaunch-runtime:fixture@direct.dzx6qo6xqzvojpv5.flympg.net/regents_prod"

        _ ->
          nil
      end)

    assert direct[:parameters][:statement_timeout] == "15000"
    assert direct[:parameters][:lock_timeout] == "5000"
    assert direct[:parameters][:idle_in_transaction_session_timeout] == "15000"
  end

  test "Fly MPG direct migration URLs use verified TLS without pooler prepares" do
    options =
      DatabaseConfig.release_config!(fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_DIRECT_URL" ->
          "postgresql://migrator:password@direct.cluster.flympg.net/regents_prod"
      end)

    refute Keyword.has_key?(options, :prepare)
    refute Keyword.has_key?(options, :max_lifetime)
    refute Keyword.has_key?(options, :parameters)
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:server_name_indication] == ~c"direct.cluster.flympg.net"
  end
end
