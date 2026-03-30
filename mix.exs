defmodule Autolaunch.MixProject do
  use Mix.Project

  def project do
    [
      app: :autolaunch,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers()
    ]
  end

  def application do
    [
      mod: {Autolaunch.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:joken, "~> 2.6"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:agent_ens, path: "../packages/agent-ens"},
      {:agent_world, path: "../packages/agent-world"},
      {:regent_ui, path: "../packages/regent_ui"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "regent.sync", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "regent.sync": [&sync_regent_assets/1],
      "assets.build": ["compile", "regent.sync", "tailwind autolaunch", "esbuild autolaunch"],
      "assets.deploy": [
        "regent.sync",
        "tailwind autolaunch --minify",
        "esbuild autolaunch --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end

  defp sync_regent_assets(_args) do
    source = Path.expand("../packages/regent_ui/priv/static/regent", __DIR__)
    destination = Path.expand("priv/static/regent", __DIR__)

    File.rm_rf!(destination)
    File.mkdir_p!(Path.dirname(destination))

    case File.cp_r(source, destination) do
      {:ok, _copied} ->
        :ok

      {:error, reason, file} ->
        Mix.raise("Failed to sync Regent assets from #{file}: #{inspect(reason)}")
    end
  end
end
