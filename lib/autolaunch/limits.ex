defmodule Autolaunch.Limits do
  @moduledoc false

  @auctions_per_account 1

  @spec auctions_per_account() :: pos_integer()
  def auctions_per_account, do: @auctions_per_account
end
