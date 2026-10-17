defmodule AutolaunchWeb.UnavailableError do
  @moduledoc """
  The record an address names could not be read just now, so the site answers
  with its 503 page, which offers to try again. A record that does not exist
  is `AutolaunchWeb.NotFoundError` instead.
  """
  defexception message: "the record at this address could not be read just now", plug_status: 503
end
