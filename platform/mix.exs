defmodule Autolaunch.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  # Branch eu/siwa-tests-out-on-autolaunch-pin-1119: the idna 8.0.0 fix line
  # (EEF-CVE-2026-117678), the two Points review fixes, the start run that also
  # records what came after the start, an award waiting or refused no longer
  # blocking a later offer, and the start run's offers waiting behind live ones,
  # one job for each while it waits; and the SIWA library folder as on
  # elixir-utils main.
  @elixir_utils_ref "fd7de50268bcbcc1ce9aa7ee217c83252a0b79bb"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "69dbfface3fdc2ab728f8cc57cface25f9c7120c"

  def project do
    [
      app: :autolaunch,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:ash_signals, :phoenix_live_view] ++ Mix.compilers(),
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
      {:ash, "~> 3.37"},
      {:assent, "== 0.3.2"},
      {:ash_phoenix, "~> 2.3.25"},
      # The v2.16.0 release includes #910: upserts use the repo's prefix, which
      # picks each site's schema on the shared database. Keep the Git pin so the
      # required-fixes check can verify the patch in its history; it stands in for
      # the copy of 2.15.2 the shared libraries pin.
      {:ash_postgres,
       git: "https://github.com/ash-project/ash_postgres.git",
       ref: "e36aa20a9f000f3f3bd89b0816fa9460156cb13c",
       override: true},
      {:ash_oban, "~> 0.10.0"},
      {:ash_ai, "~> 1.5"},
      {:oban, "~> 2.24"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:igniter, "== 0.8.5", only: :dev, runtime: false},
      {:ens_elixir, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ens"},
      {:siwa,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "siwa/siwa-elixir/apps/siwa",
       override: true},
      # regent_identity pins its own elixir-utils commit; this pin replaces it.
      {:regent_privy,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy", override: true},
      {:regent_identity,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/identity"},
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_blog, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "blog"},
      {:regent_agent_access,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access", override: true},
      # regent_mcp_agents names regent_oauth, regent_agents and regent_agent_access
      # by sibling paths; these pins replace them.
      {:regent_oauth,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "oauth", override: true},
      # The Claude connector's identity tools at /mcp (Autolaunch.Agents.Connection).
      {:regent_mcp_agents, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "mcp_agents"},
      {:regent_agents,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/agents", override: true},
      {:regent_points, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "points"},
      {:regent_format,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "format", override: true},
      {:regent_chain,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain", override: true},
      {:mdex, "== 0.14.6"},
      {:picosat_elixir, "~> 0.2.3"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: :dev, runtime: false},
      {:usage_rules, "~> 1.3.1", only: :dev, runtime: false},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:logger_json, "~> 7.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:peep, "~> 5.0"},
      {:telemetry_poller, "~> 1.3"},
      {:jason, "~> 1.2"},
      {:error_tracker, "~> 0.9"},
      # Keeps crash saving on when one save fails (RegentHttp.ErrorSaving).
      # regent_oauth names regent_http by a sibling path; this pin replaces it.
      {:regent_http, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "http", override: true},
      # Ethereum Keccak-256, which OTP's NIST `:sha3_256` is not.
      {:ex_keccak, "~> 0.7.8"},
      # Signs the transaction that finishes an ended auction.
      {:ex_secp256k1, "~> 0.8.0"},
      {:decimal, "== 3.2.0"},
      # IANA zones for the Stocks auction start; compiled in, nothing fetched at runtime.
      {:tz, "~> 0.28"},
      {:req, "== 0.7.5"},
      # The certificate list every outbound connection trusts (Autolaunch.Application).
      {:castore, "~> 1.0"},
      # Keeps the public auction list for a few seconds, so repeat callers share one read.
      {:cachex, "~> 4.1"},
      {:yaml_elixir, "== 2.12.2"},
      {:vix, "== 0.42.0"},
      {:bandit, "~> 1.14"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: :dev, runtime: false},
      {:credo_ash,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "credo_ash", only: :dev, runtime: false},
      {:sobelow, "~> 0.16", only: :dev, runtime: false}
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
        # The shared tables come first: this site's records point at the
        # shared account table, as they do in production.
        "autolaunch.shared.migrate",
        # The migration ledger follows only this flag; operations follow the
        # repo's migration_default_prefix. Both must land in autolaunch_app.
        "ash_postgres.migrate --quiet --prefix autolaunch_app"
      ],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        &clear_built_scripts/1,
        "esbuild autolaunch",
        "esbuild covered_calls",
        "esbuild exposure",
        "esbuild earn"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        &clear_built_scripts/1,
        "esbuild autolaunch --minify",
        "esbuild covered_calls --minify",
        "esbuild exposure --minify",
        "esbuild earn --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Four kinds of compile-connected edge are permitted: a domain naming
        # its compile-time resources, each resource naming the policy check
        # modules its policies use, which Ash 3.32 resolves at compile time, and
        # the endpoint naming the public documents its agent-access plug serves.
        # More stand as they are: a generic action naming the module it runs (the
        # share video request's room action, covered calls' and Exposure's
        # steps, a connected app's identity calls), the router naming the errors
        # admin page, and the router naming the hosted MCP server's input check
        # (AshAi takes it only as a function). Nothing else is permitted. The
        # ceiling is forty-four domain-to-resource edges (Accounts six,
        # Autolaunch thirty-one, CoveredCalls three, Agents, Earn, Exposure and
        # Points one each), fifty-four resource-to-check edges (including
        # Exposure preparation's shared prelaunch check; the agent
        # features' one switch check names no module, so it connects nothing),
        # the one endpoint edge, those four actions and those two router edges,
        # and it is re-based per unit when a domain, resource or check module
        # lands.
        "xref graph --label compile-connected --fail-above 105",
        "ash.codegen --check",
        "usage_rules.sync --check",
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        "cmd npm run typecheck"
      ]
    ]
  end

  # Only `esbuild autolaunch` writes priv/static/assets/js, so each build starts
  # it empty and the site ships exactly what that build made, never a file an
  # earlier build left there.
  defp clear_built_scripts(_args), do: File.rm_rf!("priv/static/assets/js")
end
