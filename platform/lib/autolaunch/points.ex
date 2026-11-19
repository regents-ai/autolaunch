defmodule Autolaunch.Points do
  @moduledoc """
  This site's part in Regent Points: what it offers Points, as it happens
  (`Autolaunch.Points.Award`), and the checks Points runs on what it offered
  (`Autolaunch.Points.Launch`, `Autolaunch.Points.Graduation`,
  `Autolaunch.Points.Bid`, `Autolaunch.Points.Trade`, `Autolaunch.Points.Stake`,
  `Autolaunch.Points.CoveredCall`, and for the account rules every Regent site
  offers, `Autolaunch.Points.AccountActivated`, `Autolaunch.Points.LinkedSocial`,
  `Autolaunch.Points.ConnectedX` and `Autolaunch.Points.PairedAgent`).
  """

  use Ash.Domain

  resources do
    resource Autolaunch.Points.Award
  end

  @doc "The name every source this site offers Points carries."
  def source_app, do: "autolaunch"
end
