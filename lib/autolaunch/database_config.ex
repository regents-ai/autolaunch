defmodule Autolaunch.DatabaseConfig do
  @moduledoc false

  @deployment_role_variable "AUTOLAUNCH_DEPLOYMENT_ROLE"
  @deployment_role_error ~s(AUTOLAUNCH_DEPLOYMENT_ROLE must be set to "production" or "staging")

  def runtime_config!(environment, getenv \\ &System.get_env/1)

  def runtime_config!(:test, _getenv), do: nil

  def runtime_config!(:prod, getenv) do
    require_deployment_role!(getenv)
    database_url!(getenv, "DATABASE_URL")
  end

  def runtime_config!(:dev, getenv), do: local_config(getenv)

  def runtime_config!(_environment, _getenv), do: nil

  def release_config!(getenv \\ &System.get_env/1) do
    require_deployment_role!(getenv)
    database_url!(getenv, "DATABASE_DIRECT_URL")
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
        |> Keyword.put(:ssl,
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        )

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
