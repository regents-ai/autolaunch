defmodule Autolaunch.DatabaseConfig do
  @moduledoc false

  @deployment_role_variable "AUTOLAUNCH_DEPLOYMENT_ROLE"
  @deployment_role_error ~s(AUTOLAUNCH_DEPLOYMENT_ROLE must be set to "production" or "staging")
  @production_hosts [
    "direct.dzx6qo6xqzvojpv5.flympg.net",
    "pgbouncer.dzx6qo6xqzvojpv5.flympg.net"
  ]

  def runtime_config!(environment, getenv \\ &System.get_env/1)

  def runtime_config!(:test, _getenv), do: nil

  def runtime_config!(:prod, getenv) do
    require_deployment_role!(getenv)

    if getenv.("DATABASE_DIRECT_URL") not in [nil, ""] do
      raise "DATABASE_DIRECT_URL belongs in the isolated migration app, not the serving app"
    end

    database_url!(getenv, "DATABASE_URL")
    |> require_runtime_target!(getenv)
    |> put_web_parameters()
    |> Keyword.merge(
      max_lifetime: 480_000..540_000,
      idle_interval: 15_000,
      backoff_type: :rand_exp,
      connect_timeout: 5_000,
      handshake_timeout: 5_000,
      show_sensitive_data_on_connection_error: false
    )
  end

  def runtime_config!(:dev, getenv), do: local_config(getenv)

  def runtime_config!(_environment, _getenv), do: nil

  def release_config!(getenv \\ &System.get_env/1) do
    require_deployment_role!(getenv)
    options = database_url!(getenv, "DATABASE_DIRECT_URL")
    host = URI.parse(options[:url]).host

    if fly_mpg_pgbouncer_host?(host) do
      raise "DATABASE_DIRECT_URL must use the direct endpoint for migration session locks"
    end

    options
  end

  defp require_runtime_target!(options, getenv) do
    if getenv.(@deployment_role_variable) == "production" do
      parsed = Ecto.Repo.Supervisor.parse_url(options[:url])

      unless String.downcase(parsed[:hostname]) in @production_hosts and
               parsed[:database] == "regents_prod" and
               parsed[:username] == "autolaunch-runtime" do
        raise "Autolaunch production must use regents_prod on its approved cluster with the runtime login"
      end
    end

    options
  end

  # PgBouncer does not generally accept arbitrary PostgreSQL startup GUCs or
  # preserve them across transaction-pooled server assignments. Keep those
  # session limits on the direct connection; do not change shared pooler policy.
  defp put_web_parameters(options) do
    parameters = [application_name: "autolaunch-web"]

    parameters =
      if fly_mpg_pgbouncer_host?(URI.parse(options[:url]).host) do
        parameters
      else
        parameters ++
          [
            statement_timeout: "15000",
            lock_timeout: "5000",
            idle_in_transaction_session_timeout: "15000"
          ]
      end

    Keyword.put(options, :parameters, parameters)
  end

  # Deployments say which venue they are. There is no default: an unset or
  # unrecognized role stops the boot before any database URL is read.
  defp require_deployment_role!(getenv) do
    case getenv.(@deployment_role_variable) do
      role when role in ["production", "staging"] -> :ok
      _unset_or_unknown -> raise @deployment_role_error
    end
  end

  defp database_url!(getenv, variable) do
    with value when is_binary(value) and value != "" <- getenv.(variable),
         {:ok, %URI{scheme: scheme, host: host, path: "/" <> database, userinfo: userinfo} = uri} <-
           parse_uri(value),
         true <- scheme in ["postgres", "postgresql"],
         true <- present?(host),
         true <- present?(database),
         true <- valid_userinfo?(userinfo),
         true <- safe_query?(uri),
         true <- safe_port?(uri),
         true <- valid_ecto_url?(value) do
      connection_options(value, String.downcase(host))
    else
      nil -> raise "#{variable} is required"
      "" -> raise "#{variable} is required"
      _ -> raise "#{variable} must be a valid PostgreSQL URL"
    end
  end

  defp parse_uri(value) do
    URI.new(value)
  rescue
    _error -> :error
  end

  defp valid_ecto_url?(value) do
    Ecto.Repo.Supervisor.parse_url(value)
    true
  rescue
    _error -> false
  end

  # Ecto turns every URL query key into an atom and merges parsed URL options
  # after the explicit Repo configuration. A managed Postgres URL therefore
  # admits no query options: even encoded or future aliases cannot weaken TLS,
  # replace the endpoint, or restore named prepares after this module's checks.
  defp safe_query?(%URI{host: host, query: query}) do
    not bound_host?(host) or query in [nil, ""]
  end

  defp safe_port?(%URI{host: host, port: port}) do
    not bound_host?(host) or port in [nil, 5432]
  end

  # A managed Postgres venue is fixed by its hostname alone, so it may carry
  # neither query options nor a port other than PostgreSQL's.
  defp bound_host?(host) when is_binary(host), do: fly_mpg_host?(host)
  defp bound_host?(_host), do: false

  defp connection_options(value, host) do
    options = [url: value, socket_options: [:inet6]]

    if fly_mpg_host?(host) do
      options =
        options
        |> Keyword.put(:port, 5432)
        |> Keyword.put(:ssl, fly_mpg_tls_options(host))

      if fly_mpg_pgbouncer_host?(host),
        do: Keyword.put(options, :prepare, :unnamed),
        else: options
    else
      options
    end
  end

  defp fly_mpg_host?(host) when is_binary(host) do
    host = String.downcase(host)
    host != "flympg.net" and String.ends_with?(host, ".flympg.net")
  end

  defp fly_mpg_host?(_host), do: false

  defp fly_mpg_pgbouncer_host?(host) do
    host |> String.downcase() |> String.starts_with?("pgbouncer.")
  end

  # The release image installs this exact Debian CA bundle path. Using the file
  # avoids decoding the entire runtime CA store eagerly while still requiring
  # both a trusted chain and a hostname match for the selected MPG endpoint.
  defp fly_mpg_tls_options(host) do
    [
      verify: :verify_peer,
      cacertfile: "/etc/ssl/certs/ca-certificates.crt",
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp local_config(getenv) do
    [
      username: getenv.("USER"),
      password: nil,
      hostname: "127.0.0.1",
      port: 5432,
      database: "autolaunch_dev",
      pool_size: 2
    ]
  end

  defp valid_userinfo?(userinfo) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> present?(username) and present?(password)
      _ -> false
    end
  end

  defp valid_userinfo?(_userinfo), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
