defmodule Autolaunch.Launch.Preview do
  @moduledoc false

  alias Autolaunch.Launch.{Internal, Params}

  def preview_launch(attrs, human) do
    Internal.preview_launch(Params.preview_attrs(attrs), human)
  end

  def create_launch_job(attrs, human, request_ip) do
    Internal.create_launch_job(Params.create_job_attrs(attrs), human, request_ip)
  end
end
