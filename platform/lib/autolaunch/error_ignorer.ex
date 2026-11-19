defmodule Autolaunch.ErrorIgnorer do
  @moduledoc """
  Leaves out two kinds of failure; everything else is kept.

  A background job's first attempt that failed when Oban will try it again
  (`state: :failure` with `"job.attempt" => 1`). The retry follows within
  seconds, or a minute for the jobs that follow the chain, so a one-off blip it
  heals is not a crash, and a fault that persists is saved when the second
  attempt fails too, with its reason. A job whose only
  or last attempt failed is kept. The failure counter
  (`autolaunch.jobs.failed.total`) still counts every failed attempt.

  An exception the site answers below 500, such as not found or a bad request.
  Anyone can raise those by visiting a wrong address, so saving them would let
  anyone fill the table. Server faults in requests and pages, exits and throws
  are kept.
  """

  @behaviour ErrorTracker.Ignorer

  @impl ErrorTracker.Ignorer
  def ignore?(_error, %{:state => :failure, "job.attempt" => 1}), do: true

  def ignore?(%ErrorTracker.Error{kind: "Elixir." <> _module = kind}, _context),
    do: kind |> String.to_existing_atom() |> visitors?()

  def ignore?(_error, _context), do: false

  # Ash's four error classes take their status from the errors they wrap, so the
  # class names whose doing it was: bad input or a refusal, or a server fault.
  defp visitors?(class) when class in [Ash.Error.Invalid, Ash.Error.Forbidden], do: true
  defp visitors?(class) when class in [Ash.Error.Unknown, Ash.Error.Framework], do: false

  defp visitors?(exception),
    do:
      Code.ensure_loaded?(exception) and function_exported?(exception, :exception, 1) and
        Plug.Exception.status(exception.__struct__()) < 500
end
