defmodule AutolaunchWeb.NotFoundError do
  @moduledoc "Nothing lives at the address asked for; the site answers with its 404 page."
  defexception message: "nothing lives at this address", plug_status: 404
end
