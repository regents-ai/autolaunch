defmodule Autolaunch.DatabaseConfigTest do
  use ExUnit.Case, async: true

  alias Autolaunch.DatabaseConfig

  test "Fly MPG runtime URLs require verified TLS and unnamed pooler prepares" do
    options =
      DatabaseConfig.runtime_config!(:prod, fn
        "AUTOLAUNCH_DEPLOYMENT_ROLE" ->
          "production"

        "DATABASE_URL" ->
          "postgresql://runtime:password@pgbouncer.cluster.flympg.net/regents_prod"
      end)

    assert options[:prepare] == :unnamed
    assert options[:socket_options] == [:inet6]
    assert options[:port] == 5432
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:cacertfile] == "/etc/ssl/certs/ca-certificates.crt"
    assert options[:ssl][:server_name_indication] == ~c"pgbouncer.cluster.flympg.net"
    assert is_function(options[:ssl][:customize_hostname_check][:match_fun], 2)
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
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:server_name_indication] == ~c"direct.cluster.flympg.net"
  end
end
