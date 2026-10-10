defmodule Autolaunch.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "1564d79eb3b653f06ab11b6c422bd4d6283ea199"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "4da6db2bfe3559a8f8a761018dc099a28ab5f6a3"
  @regents "https://github.com/regents-ai/regents.git"
  @regents_ref "004307e65ffcf9cc9b3034d7cc2b015dcd45011b"

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
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules()
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
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix usage_rules.sync` writes the marked block at the end of AGENTS.md: how to
  # read the installed version's docs, and links to each package's own rules in deps/.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:usage_rules, sub_rules: []},
        {:usage_rules, sub_rules: :all, main: false, link: :markdown},
        {:ash, link: :markdown},
        {~r/^ash_/, link: :markdown},
        {:phoenix, sub_rules: ["phoenix", "liveview", "html"], link: :markdown}
      ]
    ]
  end

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
      {:ash, "~> 3.34 and >= 3.34.6"},
      {:assent, "== 0.3.1"},
      {:ash_phoenix, "~> 2.3"},
      # 2.13.1 through 2.14.2 send upserts to the public schema, ignoring the
      # repo's prefix that picks Autolaunch's schema on the shared database.
      {:ash_postgres, "== 2.13.0"},
      {:ash_oban, "~> 0.9.0"},
      {:oban, "~> 2.24"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false},
      {:ens_elixir, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ens"},
      {:siwa,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "siwa/siwa-elixir/apps/siwa",
       override: true},
      {:regent_privy,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy", override: true},
      {:regent_identity, git: @regents, ref: @regents_ref, sparse: "identity"},
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_blog, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "blog"},
      {:regent_agent_access, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access"},
      {:regent_agents,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/agents", override: true},
      {:regent_credits, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "credits"},
      {:regent_points, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "points"},
      {:regent_format, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "format"},
      {:regent_chain,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain", override: true},
      {:mdex, "== 0.13.3"},
      {:picosat_elixir, "~> 0.2.3"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      # In :test too, because precommit runs in :test and checks the synced block.
      {:usage_rules, "~> 1.2.8", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:jason, "~> 1.2"},
      # Ethereum Keccak-256 for EIP-55, which OTP's NIST `:sha3_256` is not.
      {:jose, "~> 1.11.12"},
      # Signs the transaction that finishes an ended auction.
      {:ex_secp256k1, "~> 0.8.0"},
      {:decimal, "== 3.1.1"},
      # IANA zones for the Stocks auction start; compiled in, nothing fetched at runtime.
      {:tz, "~> 0.28"},
      {:req, "== 0.7.4"},
      # Keeps the public auction list for a few seconds, so repeat callers share one read.
      {:cachex, "~> 4.1"},
      {:yaml_elixir, "== 2.12.2"},
      {:vix, "== 0.41.0"},
      {:bandit, "~> 1.12.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo_ash,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "credo_ash",
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
      setup: [
        "deps.get",
        "cmd npm ci",
        "db.setup",
        "assets.setup",
        "assets.build"
      ],
      "db.setup": [
        "ash_postgres.create --quiet",
        "autolaunch.schema.create",
        # The migration ledger follows only this flag; operations follow the
        # repo's migration_default_prefix. Both must land in autolaunch_app.
        "ash_postgres.migrate --quiet --prefix autolaunch_app",
        "autolaunch.identity.migrate"
      ],
      test: ["db.setup", "test"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        "esbuild autolaunch",
        "esbuild autolaunch_crown"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        "esbuild autolaunch --minify",
        "esbuild autolaunch_crown --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Two kinds of compile-connected edge are permitted: a domain naming
        # its compile-time resources, and each resource naming the policy check
        # modules its policies use, which Ash 3.32 resolves at compile time.
        # Nothing else is permitted. The ceiling is twenty-nine domain-to-resource
        # edges (Accounts four, Autolaunch twenty-five) plus thirty-eight
        # resource-to-check edges, and it is re-based per unit when a domain,
        # resource or check module lands.
        "xref graph --label compile-connected --fail-above 68",
        "test --warnings-as-errors",
        "ash.codegen --check",
        "usage_rules.sync --check"
      ]
    ]
  end
end
