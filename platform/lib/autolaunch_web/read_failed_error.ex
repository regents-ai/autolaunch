defmodule AutolaunchWeb.ReadFailedError do
  @moduledoc """
  The record an address names could not be read, for a reason other than a
  lost database connection (`AutolaunchWeb.ReadFailure`), so the site answers
  with its plain 500 page. A lost connection is `AutolaunchWeb.UnavailableError`
  instead, and a record that does not exist `AutolaunchWeb.NotFoundError`.
  """
  defexception message: "the record at this address could not be read", plug_status: 500
end
