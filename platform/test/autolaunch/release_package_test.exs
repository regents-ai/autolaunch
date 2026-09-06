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
    # inputs — Mix cache, npm manifests and npm cache — host build artifacts
    # under a dependency's priv, a sibling's tests, lockfile, tooling files,
    # digested output and JavaScript, environment files, and everything outside
    # the declared allowlist. A real context carries one bundler executable; the
    # rules admit either architecture's name.
    write_files(context, [
      {"platform/lib/app.ex", "defmodule App do\nend\n"},
      {"platform/config/config.exs", "import Config\n"},
      {"platform/assets/js/app.ts", "export const app = 1\n"},
      {"platform/contracts/api-contract.openapiv3.yaml", "openapi: 3.1.0\n"},
      {"platform/rel/overlays/bin/migrate", "#!/bin/sh\n"},
      {"platform/priv/static/app.css", "body{}\n"},
      {"platform/mix.exs", "defmodule App.MixProject do\nend\n"},
      {"platform/mix.lock", "%{}\n"},
      {"platform/package.json", "{}\n"},
      {"platform/package-lock.json", "{}\n"},
      {"platform/deps/dependency/lib/dependency.ex", "defmodule Dependency do\nend\n"},
      {"platform/deps/dependency/priv/static/dependency.js", "export const dep = 1\n"},
      {"platform/deps/dependency/priv/templates/generator.eex", "<%= @thing %>\n"},
      {"platform/deps/dependency/priv/host_listener", "host build output\n"},
      {"platform/deps/dependency/priv/nif.so", "host build output\n"},
      {"platform/test/app_test.exs", "defmodule AppTest do\nend\n"},
      {"platform/docs/guide.md", "# guide\n"},
      {"platform/README.md", "# readme\n"},
      {"platform/.env", "SECRET=nope\n"},
      {"platform/.env.example", "SECRET=\n"},
      {"platform/.env.production", "SECRET=nope\n"},
      {"platform/.envrc", "export SECRET=nope\n"},
      {"platform/config/.env", "SECRET=nope\n"},
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
      {"regents/identity/lib/profile.ex", "fixture"},
      {"regents/identity/.env", "private fixture"},
      {"design-system/regent_ui/assets/js/profile.mjs", "export {}"},
      {"design-system/regent_ui/priv/static/images/autolaunch-dark.svg", "<svg/>"},
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

    assert admitted_files(output) ==
             Enum.sort([
               "platform/assets/js/app.ts",
               "platform/config/config.exs",
               "platform/contracts/api-contract.openapiv3.yaml",
               "platform/lib/app.ex",
               "platform/mix.exs",
               "platform/mix.lock",
               "platform/package-lock.json",
               "platform/package.json",
               "platform/priv/static/app.css",
               "platform/rel/overlays/bin/migrate",
               "design-system/regent_ui/assets/css/regent.css",
               "design-system/regent_ui/assets/js/regent.ts",
               "design-system/regent_ui/lib/regent_ui.ex",
               "design-system/regent_ui/mix.exs",
               "elixir-utils/privy/lib/privy.ex",
               "regents/identity/lib/profile.ex",
               "design-system/regent_ui/assets/js/profile.mjs",
               "design-system/regent_ui/priv/static/images/autolaunch-dark.svg"
             ])
  end

  test "context assembly excludes private files and host output and refuses existing destinations" do
    fixture = temporary_directory("assembly")
    source = Path.join(fixture, "platform")
    destination = Path.join(fixture, "context")

    write_files(source, [
      {"mix.exs", "fixture"},
      {"mix.lock", "%{}"},
      {"package-lock.json", "{}"},
      {"Dockerfile", "FROM scratch"},
      {"Dockerfile.dockerignore", "*"},
      {"lib/app.ex", "fixture"},
      {".env", "private fixture"},
      {"config/.ENV.local", "private fixture"},
      {"deps/host/priv/native.so", "host output"},
      {"node_modules/host.js", "host output"},
      {"_build/native.so", "host output"}
    ])

    script = Path.join(source, "scripts/build-release-context.sh")
    File.mkdir_p!(Path.dirname(script))
    File.cp!(@context_script, script)

    env =
      for {name, directory} <- [{"PRIVY", "privy"}, {"IDENTITY", "identity"}, {"UI", "ui"}],
          reduce: [] do
        result ->
          package = Path.join(fixture, directory)

          write_files(package, [
            {"mix.exs", "fixture"},
            {"lib/package.ex", directory},
            {".envrc", "private fixture"},
            {"_build/native.so", "host output"}
          ])

          [
            {"REGENT_#{name}_PATH", package},
            {"REGENT_#{name}_REVISION", String.duplicate("a", 40)} | result
          ]
      end

    File.ln_s!(Path.join(source, "lib/app.ex"), Path.join(source, "external-link"))

    {output, status} =
      System.cmd("bash", [script, destination, "arm64"], env: env, stderr_to_stdout: true)

    assert status == 0, output
    files = admitted_files(destination)

    for expected <- [
          "platform/lib/app.ex",
          "elixir-utils/privy/lib/package.ex",
          "regents/identity/lib/package.ex",
          "design-system/regent_ui/lib/package.ex",
          "BUILD-INPUTS.txt"
        ] do
      assert expected in files
    end

    refute Enum.any?(files, fn path ->
             String.contains?(String.downcase(path), ".env") or
               String.contains?(path, ["node_modules/", "_build/", "deps/", "external-link"])
           end)

    before = Map.new(files, fn path -> {path, File.read!(Path.join(destination, path))} end)

    {output, status} =
      System.cmd("bash", [script, destination, "arm64"], env: env, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "destination already exists"

    assert before ==
             Map.new(admitted_files(destination), fn path ->
               {path, File.read!(Path.join(destination, path))}
             end)

    {output, status} =
      System.cmd("bash", [script, Path.join(source, "recursive"), "arm64"],
        env: env,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "outside every source tree"
  end

  defp temporary_directory(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "platform-#{prefix}-#{System.unique_integer([:positive])}"
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
