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
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Autolaunch.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.external": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.6", override: true},
      {:ash, "~> 3.29.3"},
      {:assent, "== 0.3.1"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_postgres, "~> 2.10.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:igniter, "== 0.8.2", only: [:dev, :test], runtime: false},
      {:regent_privy, path: "../elixir-utils/privy"},
      {:regent_ui, path: "../design-system/regent_ui"},
      {:picosat_elixir, "~> 0.2.3"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.12.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo_ash, path: "../elixir-utils/credo_ash", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "cmd npm ci", "ash.setup", "assets.setup", "assets.build"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild autolaunch"],
      "assets.deploy": [
        "esbuild autolaunch --minify",
        "phx.digest"
      ],
      "test.external": ["test --only external"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # The Accounts domain names its four resources at compile time, which is
        # how Ash.Domain declares them. Nothing else is compile-connected.
        "xref graph --label compile-connected --fail-above 4",
        "test --warnings-as-errors",
        "ash.codegen --check"
      ]
    ]
  end
end
