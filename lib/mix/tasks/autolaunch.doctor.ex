defmodule Mix.Tasks.Autolaunch.Doctor do
  use Mix.Task

  @shortdoc "Checks launch-blocking dependencies and warns on optional trust dependencies"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    result = Autolaunch.ReleaseDoctor.run()

    Enum.each(result.checks, fn check ->
      label =
        case {check.ok, check.severity} do
          {true, :warning} -> "WARN-OK"
          {true, _} -> "OK"
          {false, :warning} -> "WARN"
          {false, _} -> "FAIL"
        end

      Mix.shell().info("[#{label}] #{check.key}: #{check.detail}")
    end)

    if result.ok do
      Mix.shell().info("Autolaunch doctor passed.")
    else
      Mix.raise("Autolaunch doctor failed.")
    end
  end
end
