defmodule Autolaunch.Launch.Jobs do
  @moduledoc false

  alias Autolaunch.Launch.Internal

  def get_job_response(job_id, owner_address \\ nil),
    do: Internal.get_job_response(job_id, owner_address)

  def queue_processing(job_id), do: Internal.queue_processing(job_id)
  def terminal_status?(status), do: Internal.terminal_status?(status)
  def process_job(job_id), do: Internal.process_job(job_id)
end
