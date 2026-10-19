defmodule AutolaunchWeb.ReadFailure do
  @moduledoc """
  A database read or write that failed, sorted the one way the site sorts it:
  the database could not be reached (`:connection_lost`), or something else
  went wrong (`:failed`). Only a lost connection is the try-again page (503,
  `AutolaunchWeb.UnavailableError`); anything else is the plain error page
  (500, `AutolaunchWeb.ReadFailedError`).

  A failure is logged where it is sorted, so none passes unseen. The line names
  only the kind and the module of each error Ash hands over, with the code of a
  real `Postgrex.Error`, never any of an error's text, so no wallet, address or
  other value reaches the log.
  """

  require Logger

  alias AutolaunchWeb.{ReadFailedError, UnavailableError}

  @doc """
  Logs `error` under `what` ("market page read") and answers with its page:
  raises `AutolaunchWeb.UnavailableError` for a lost connection and
  `AutolaunchWeb.ReadFailedError` for anything else.
  """
  @spec raise!(String.t(), term()) :: no_return()
  def raise!(what, error) do
    case log(what, error) do
      :connection_lost -> raise UnavailableError
      :failed -> raise ReadFailedError
    end
  end

  @doc """
  Logs `error` under `what`, a lost connection as a warning and anything else
  as an error, and returns its kind.
  """
  @spec log(String.t(), term()) :: :connection_lost | :failed
  def log(what, error) do
    kind = if lost_connection?(error), do: :connection_lost, else: :failed
    Logger.log(level(kind), "#{what} #{kind}: #{named(error)}")
    kind
  end

  defp level(:connection_lost), do: :warning
  defp level(:failed), do: :error

  @doc """
  The kind and module of each error in `error`, with a `Postgrex.Error`'s
  code; none of an error's text. An atom is a reason named by the site, such
  as `:invalid_query`, and is its own name.
  """
  @spec named(term()) :: String.t()
  def named(%Postgrex.Error{postgres: %{pg_code: code}}), do: "Postgrex.Error #{code}"
  def named(%{errors: errors}) when is_list(errors), do: Enum.map_join(errors, ", ", &named/1)
  def named(%struct{}), do: inspect(struct)
  def named(reason) when is_atom(reason), do: Atom.to_string(reason)

  # A lost connection: the connection's own error, or a Postgres error whose
  # code is a connection exception (class 08) or a server shutting down or
  # starting (57P01 to 57P03).
  @connection_codes ~w(08000 08001 08003 08004 08006 08007 08P01 57P01 57P02 57P03)

  # AshPostgres keeps only the formatted text of an exception it did not
  # expect (`handle_raised_error/4` in deps/ash_postgres/lib/data_layer.ex
  # hands it to Splode's `to_error/2`, which stores
  # `Exception.format(:error, exception)` in `Ash.Error.Unknown.UnknownError`),
  # so for that one error a lost connection is told by the banner the text
  # starts with. The check gives only true or false.
  # The banners assume the database server reports its messages in English.
  @lost_banners ["** (DBConnection.ConnectionError) "] ++
                  for(
                    severity <- ~w(ERROR FATAL PANIC),
                    code <- @connection_codes,
                    do: "** (Postgrex.Error) #{severity} #{code} "
                  )

  @doc "Whether `error` is, or holds, a lost database connection."
  @spec lost_connection?(term()) :: boolean()
  def lost_connection?(%DBConnection.ConnectionError{}), do: true

  def lost_connection?(%Postgrex.Error{postgres: %{pg_code: code}}),
    do: code in @connection_codes

  def lost_connection?(%Ash.Error.Unknown.UnknownError{error: text}) when is_binary(text),
    do: String.starts_with?(text, @lost_banners)

  def lost_connection?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &lost_connection?/1)

  def lost_connection?(_other), do: false
end
