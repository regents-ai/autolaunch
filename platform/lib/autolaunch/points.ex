defmodule Autolaunch.Points do
  @moduledoc "This site's part in Regent Points: what it offers Points, as it happens."

  use Ash.Domain

  resources do
    resource Autolaunch.Points.Award
  end
end
