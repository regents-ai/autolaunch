defmodule Autolaunch.Signals do
  @moduledoc """
  What launches tell the rest of the site, as Ash signals. Each is emitted in
  the transaction of the write that saved it, so a listener with the default
  delivery commits or rolls back with it. Points offers both to Regent Points
  (`Autolaunch.Points.Award`).

    * `:launch_recorded`: a launch's auction row was saved for the first time
      (`Autolaunch.Auction` `:record_launch`), by whichever of its writers came
      first. A later write of the same launch emits nothing.
    * `:token_graduated`: a graduated launch's token row was saved for the
      first time (`Autolaunch.Token` `:project_lab`). Projecting the same
      graduation again emits nothing.
  """

  use Ash.Signals

  signals do
    signal :launch_recorded do
      argument :auction_id, :uuid, allow_nil?: false
    end

    signal :token_graduated do
      argument :token_id, :uuid, allow_nil?: false
    end
  end
end
