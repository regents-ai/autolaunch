defmodule Mix.Tasks.Autolaunch.Smoke do
  use Mix.Task

  @shortdoc "Runs a synthetic release smoke for the launch-to-subject pipeline"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    result = Autolaunch.ReleaseSmoke.run()

    Enum.each(result.checks, fn check ->
      Mix.shell().info("[OK] #{check.key}: #{check.detail}")
    end)

    Mix.shell().info("Smoke job: #{result.job_id}")
    Mix.shell().info("Smoke subject: #{result.subject_id}")
    Mix.shell().info("Autolaunch smoke passed.")
  end
end
