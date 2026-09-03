defmodule Autolaunch.BidIdentity do
  @moduledoc """
  Canonical bid IDs occupy one URL-safe segment.

  They match `\\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\\z`, the same identifier
  format accepted by the route catalog.
  """

  @pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/

  @doc false
  def constraints do
    [min_length: 1, max_length: 128, trim?: false, match: @pattern]
  end
end
