defmodule Autolaunch.Portfolio.RefreshJobs do
  @moduledoc false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Portfolio

  def start(%HumanUser{} = human) do
    case Task.Supervisor.start_child(Autolaunch.TaskSupervisor, fn ->
           Portfolio.refresh_snapshot(human)
         end) do
      {:ok, _pid} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
