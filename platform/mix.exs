defmodule Autolaunch.MixProject do
  use Mix.Project

  def project do
    [
      app: :autolaunch,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["core_tests/elixir"],
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
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "core_tests/elixir/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    shared = System.get_env("REGENT_DEPS_ROOT", Path.expand("../..", __DIR__))

    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.6", override: true},
      {:ash, "~> 3.33.0"},
      {:assent, "== 0.3.1"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_postgres, "~> 2.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false},
      {:regent_privy,
       path: System.get_env("REGENT_PRIVY_PATH", Path.join(shared, "elixir-utils/privy"))},
      {:regent_identity,
       path: System.get_env("REGENT_IDENTITY_PATH", Path.join(shared, "regents/identity"))},
      {:regent_ui,
       path: System.get_env("REGENT_UI_PATH", Path.join(shared, "design-system/regent_ui"))},
      {:picosat_elixir, "~> 0.2.3"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      # Ethereum Keccak-256 for EIP-55, which OTP's NIST `:sha3_256` is not.
      {:jose, "~> 1.11.12"},
      {:decimal, "== 3.1.1"},
      {:req, "== 0.7.4"},
      {:yaml_elixir, "== 2.12.2"},
      {:vix, "== 0.41.0"},
      {:bandit, "~> 1.12.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo_ash,
       path:
         Path.join(
           System.get_env("REGENT_DEPS_ROOT", Path.expand("../..", __DIR__)),
           "elixir-utils/credo_ash"
         ),
       only: [:dev, :test],
       runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false}
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
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_identity.assets",
        "esbuild autolaunch",
        "esbuild autolaunch_crown"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_identity.assets",
        "esbuild autolaunch --minify",
        "esbuild autolaunch_crown --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Two kinds of compile-connected edge are permitted: a domain naming
        # its compile-time resources, and each resource naming the policy check
        # modules its policies use, which Ash 3.32 resolves at compile time.
        # Nothing else is permitted. The ceiling is sixteen domain-to-resource
        # edges (Accounts four, Autolaunch twelve) plus twenty-four
        # resource-to-check edges, and it is re-based per unit when a domain,
        # resource or check module lands.
        "xref graph --label compile-connected --fail-above 40",
        "test --warnings-as-errors",
        "ash.codegen --check"
      ]
    ]
  end
end
