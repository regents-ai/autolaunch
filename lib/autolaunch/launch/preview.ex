defmodule Autolaunch.Launch.Preview do
  @moduledoc false

  alias Autolaunch.Launch.{Core, Params}

  def preview_launch(attrs, human) do
    Core.preview_launch(Params.preview_attrs(attrs), human)
  end

  def create_launch_job(attrs, human, request_ip) do
    Core.create_launch_job(Params.create_job_attrs(attrs), human, request_ip)
  end

  def create_launch_job(attrs, human, request_ip, opts) do
    Core.create_launch_job(Params.create_job_attrs(attrs), human, request_ip, opts)
  end
end
