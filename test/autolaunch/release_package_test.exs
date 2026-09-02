defmodule Autolaunch.ReleasePackageTest do
  use ExUnit.Case, async: true

  @package_root Path.expand("../..", __DIR__)
  @dockerfile Path.join(@package_root, "Dockerfile")
  @dockerignore Path.join(@package_root, "Dockerfile.dockerignore")
  @fly_template Path.join(@package_root, "fly.toml")
  @fly_staging_template Path.join(@package_root, "fly.staging.toml")
  @context_script Path.join(@package_root, "scripts/build-release-context.sh")
  @release_commands ~w(migrate pending-migrations)

  test "PKG-IMAGE and PKG-TEMPLATE ship the release package files" do
    assert File.regular?(@dockerfile)
    assert File.regular?(@dockerignore)
    assert File.regular?(@fly_template)
    assert File.regular?(@fly_staging_template)
    assert File.regular?(@context_script)
    assert File.stat!(@context_script).mode |> Bitwise.band(0o100) != 0
  end

  test "PKG-IMAGE ships every release command as an executable overlay" do
    for command <- @release_commands do
      path = Path.join(@package_root, "rel/overlays/bin/#{command}")

      assert File.regular?(path), "#{command} is missing from the release overlay"

      assert File.stat!(path).mode |> Bitwise.band(0o100) != 0,
             "#{command} would not ship executable"
    end
  end

  # Reading the ignore rules cannot tell you what they admit: a bare directory
  # re-include silently readmits everything beneath it. Only a real build knows,
  # so this asks one. It is tagged :external because it needs a Docker daemon.
  @tag :external
  test "PKG-CONTEXT the ignore rules admit exactly the declared package inputs" do
    context = temporary_directory("release-context")
    output = temporary_directory("release-context-out")

    # A miniature stand-in for the real parent context, holding one file for
    # every rule: package sources, the sibling Privy source, the narrow slice of
    # the RegentUI source the build compiles and styles from, the sealed offline
    # inputs, and the things that must never enter -- host build artifacts under
    # a dependency's priv, a sibling's tests, lockfile, tooling files, digested
    # output and JavaScript, environment files, and everything outside the
    # declared allowlist. A real context carries one bundler executable; the
    # rules admit either architecture's name.
    write_files(context, [
      {"autolaunch-web/lib/app.ex", "defmodule App do\nend\n"},
      {"autolaunch-web/config/config.exs", "import Config\n"},
      {"autolaunch-web/assets/js/app.ts", "export const app = 1\n"},
      {"autolaunch-web/contracts/api-contract.openapiv3.yaml", "openapi: 3.1.0\n"},
      {"autolaunch-web/rel/overlays/bin/migrate", "#!/bin/sh\n"},
      {"autolaunch-web/priv/static/app.css", "body{}\n"},
      {"autolaunch-web/mix.exs", "defmodule App.MixProject do\nend\n"},
      {"autolaunch-web/mix.lock", "%{}\n"},
      {"autolaunch-web/package.json", "{}\n"},
      {"autolaunch-web/package-lock.json", "{}\n"},
      {"autolaunch-web/deps/dependency/lib/dependency.ex", "defmodule Dependency do\nend\n"},
      {"autolaunch-web/deps/dependency/priv/static/dependency.js", "export const dep = 1\n"},
      {"autolaunch-web/deps/dependency/priv/templates/generator.eex", "<%= @thing %>\n"},
      {"autolaunch-web/deps/dependency/priv/host_listener", "host build output\n"},
      {"autolaunch-web/deps/dependency/priv/nif.so", "host build output\n"},
      {"autolaunch-web/test/app_test.exs", "defmodule AppTest do\nend\n"},
      {"autolaunch-web/docs/guide.md", "# guide\n"},
      {"autolaunch-web/README.md", "# readme\n"},
      {"autolaunch-web/.env", "SECRET=nope\n"},
      {"autolaunch-web/.env.example", "SECRET=\n"},
      {"autolaunch-web/.env.production", "SECRET=nope\n"},
      {"autolaunch-web/.envrc", "export SECRET=nope\n"},
      {"autolaunch-web/config/.env", "SECRET=nope\n"},
      {"elixir-utils/privy/lib/privy.ex", "defmodule Privy do\nend\n"},
      {"elixir-utils/unrelated/lib/unrelated.ex", "defmodule Unrelated do\nend\n"},
      {"design-system/regent_ui/mix.exs", "defmodule RegentUi.MixProject do\nend\n"},
      {"design-system/regent_ui/lib/regent_ui.ex", "defmodule RegentUi do\nend\n"},
      {"design-system/regent_ui/assets/css/regent.css", ":root{}\n"},
      {"design-system/regent_ui/assets/js/regent.ts", "export const regent = 1\n"},
      {"design-system/regent_ui/priv/static/regent/sigil-3f9a.svg", "<svg/>\n"},
      {"design-system/regent_ui/test/regent/components_test.exs", "defmodule T do\nend\n"},
      {"design-system/regent_ui/deps/dependency/priv/nif.so", "host build output\n"},
      {"design-system/regent_ui/.claude/settings.json", "{}\n"},
      {"design-system/regent_ui/mix.lock", "%{}\n"},
      {"design-system/regent_ui/.formatter.exs", "[]\n"},
      {"design-system/unrelated/lib/unrelated.ex", "defmodule Unrelated do\nend\n"},
      {"mix-cache/archives/hex", "hex archive\n"},
      {"npm-cache/_cacache/content", "cache payload\n"},
      {"esbuild-linux-arm64", "bundler\n"},
      {"esbuild-linux-x64", "bundler\n"},
      {"stray.txt", "outside the allowlist\n"}
    ])

    dockerfile = Path.join(context, "context.Dockerfile")
    File.write!(dockerfile, "FROM scratch\nCOPY . /\n")
    File.cp!(@dockerignore, Path.join(context, "context.Dockerfile.dockerignore"))

    {out, status} =
      System.cmd(
        "docker",
        [
          "build",
          "--network=none",
          "--pull=false",
          "--quiet",
          "--file",
          dockerfile,
          "--output",
          "type=local,dest=#{output}",
          context
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out

    assert admitted_files(output) == [
             "autolaunch-web/assets/js/app.ts",
             "autolaunch-web/config/config.exs",
             "autolaunch-web/contracts/api-contract.openapiv3.yaml",
             "autolaunch-web/deps/dependency/lib/dependency.ex",
             "autolaunch-web/deps/dependency/priv/static/dependency.js",
             "autolaunch-web/deps/dependency/priv/templates/generator.eex",
             "autolaunch-web/lib/app.ex",
             "autolaunch-web/mix.exs",
             "autolaunch-web/mix.lock",
             "autolaunch-web/package-lock.json",
             "autolaunch-web/package.json",
             "autolaunch-web/priv/static/app.css",
             "autolaunch-web/rel/overlays/bin/migrate",
             "design-system/regent_ui/assets/css/regent.css",
             "design-system/regent_ui/lib/regent_ui.ex",
             "design-system/regent_ui/mix.exs",
             "elixir-utils/privy/lib/privy.ex",
             "esbuild-linux-arm64",
             "esbuild-linux-x64",
             "mix-cache/archives/hex",
             "npm-cache/_cacache/content"
           ]
  end

  # The three CTX-ENV cases below execute the exact filter list and the exact
  # guard the context script defines, lifted from its own source rather than
  # transcribed. What they do not prove is that a full run of the script
  # publishes a clean context: the script verifies its sealed supply before it
  # assembles anything, and no sealed supply for this repository exists yet, so
  # nothing here runs the script end to end.

  test "CTX-ENV the script's env filters keep every env-shaped file out of a copy" do
    filters = env_filters()

    assert filters != [],
           "an empty filter list would expand to nothing and copy the env files"

    source = temporary_directory("context-filter-source")
    destination = temporary_directory("context-filter-destination")

    write_files(source, [
      {".env", "SECRET=nope\n"},
      {".env.local", "SECRET=nope\n"},
      {".env.production", "SECRET=nope\n"},
      {".env.example", "SECRET=\n"},
      {".envrc", "export SECRET=nope\n"},
      {".envrc.local", "export SECRET=nope\n"},
      {"config/.env", "SECRET=nope\n"},
      {"a/b/.env", "SECRET=nope\n"},
      {"lib/app.ex", "defmodule App do\nend\n"},
      {"config/config.exs", "import Config\n"},
      {"a/b/keep.txt", "keep me\n"},
      {"environment.md", "# not a secrets file\n"}
    ])

    File.mkdir_p!(destination)

    {out, status} =
      System.cmd("rsync", ["-a"] ++ filters ++ ["#{source}/", "#{destination}/"],
        stderr_to_stdout: true
      )

    assert status == 0, out

    assert admitted_files(destination) == [
             "a/b/keep.txt",
             "config/config.exs",
             "environment.md",
             "lib/app.ex"
           ]
  end

  test "CTX-ENV every source-tree copy takes the env filters and only the cache skips them" do
    lines = script_lines()

    assert Enum.count(lines, &String.starts_with?(&1, "env_filters=(")) == 1,
           "the filter list must be defined exactly once"

    rsync_calls =
      lines
      |> join_continuations()
      |> Enum.filter(&String.starts_with?(&1, "rsync "))

    assert length(rsync_calls) == 4

    {filtered, unfiltered} =
      Enum.split_with(rsync_calls, &String.contains?(&1, ~s("${env_filters[@]}")))

    for source <- [~s("$repo_root/"), ~s("$privy_source/"), ~s("$regent_ui_source/")] do
      assert Enum.count(filtered, &String.contains?(&1, source)) == 1,
             "the copy of #{source} must take the env filters"
    end

    assert length(filtered) == 3

    assert [npm_cache_copy] = unfiltered
    assert String.contains?(npm_cache_copy, "npm-cache")
  end

  test "CTX-ENV the script's guard refuses a staging tree carrying an env-shaped file" do
    {scan, refusal} = context_guard()

    dirty = temporary_directory("context-guard-dirty")

    write_files(dirty, [
      {"autolaunch-web/lib/app.ex", "defmodule App do\nend\n"},
      {"mix-cache/x/.envrc.local", "export SECRET=nope\n"}
    ])

    {out, status} = run_guard(scan, refusal, dirty)

    assert status == 1
    assert out =~ "mix-cache/x/.envrc.local"

    # The copy filters are case-sensitive and rsync offers no portable way to
    # change that, so an oddly cased name reaches the staging tree; the guard is
    # the only thing standing between it and an upload.
    odd_case = temporary_directory("context-guard-odd-case")

    write_files(odd_case, [
      {"autolaunch-web/lib/app.ex", "defmodule App do\nend\n"},
      {"autolaunch-web/.ENV", "SECRET=nope\n"}
    ])

    {out, status} = run_guard(scan, refusal, odd_case)

    assert status == 1
    assert out =~ ".ENV"

    clean = temporary_directory("context-guard-clean")

    write_files(clean, [
      {"autolaunch-web/lib/app.ex", "defmodule App do\nend\n"},
      {"autolaunch-web/environment.md", "# not a secrets file\n"},
      {"mix-cache/archives/hex", "hex archive\n"}
    ])

    assert run_guard(scan, refusal, clean) == {"", 0}
  end

  defp script_lines do
    @context_script
    |> File.read!()
    |> String.split("\n")
  end

  defp join_continuations(lines) do
    lines
    |> Enum.join("\n")
    |> String.replace(~r/\\\n\s*/, " ")
    |> String.split("\n")
  end

  # Runs the script's own `env_filters=(...)` line and reports the arguments it
  # produces, so the copy under test receives exactly what the script passes.
  defp env_filters do
    [definition] = Enum.filter(script_lines(), &String.starts_with?(&1, "env_filters=("))

    {out, status} =
      System.cmd(
        "bash",
        ["-c", "set -u\n" <> definition <> "\nprintf '%s\\0' \"${env_filters[@]}\""],
        stderr_to_stdout: true
      )

    assert status == 0, out

    String.split(out, <<0>>, trim: true)
  end

  # The guard is the `offender=` scan and the refusal on the line right after it.
  # Where it sits is half of what makes it a guard: it has to run after the
  # sealed archive is unpacked, so it sees those files, and before the previous
  # destination is removed, so a refusal leaves that context in place.
  defp context_guard do
    lines = script_lines()

    [index] = script_line_indexes(lines, &String.starts_with?(&1, "offender="))
    [unpack] = script_line_indexes(lines, &String.starts_with?(&1, "tar -xf "))
    [delete] = script_line_indexes(lines, &String.contains?(&1, ~s(rm -rf -- "$destination")))

    assert index > unpack, "the scan must run after the sealed archive is unpacked"
    assert index < delete, "the scan must run before the previous destination is removed"

    refusal = Enum.at(lines, index + 1)

    assert String.starts_with?(refusal, ~s([ -z "$offender" ] ||)),
           "the refusal must follow the scan immediately"

    {Enum.at(lines, index), refusal}
  end

  defp script_line_indexes(lines, matches?) do
    for {line, index} <- Enum.with_index(lines), matches?.(String.trim(line)), do: index
  end

  defp run_guard(scan, refusal, staging) do
    preamble = """
    set -euo pipefail
    die() { printf '%s\\n' "$*"; exit 1; }
    staging='#{staging}'
    """

    System.cmd("bash", ["-c", preamble <> scan <> "\n" <> refusal <> "\n"],
      stderr_to_stdout: true
    )
  end

  defp temporary_directory(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "autolaunch-web-#{prefix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_files(root, entries) do
    Enum.each(entries, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp admitted_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end
end
