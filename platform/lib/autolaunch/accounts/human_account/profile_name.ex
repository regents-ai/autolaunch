defmodule Autolaunch.Accounts.HumanAccount.ProfileName do
  @moduledoc """
  The name a person set in their shared Regent profile (edited through
  `/profile`, read through `Autolaunch.Accounts.SharedProfile`), the same on
  every Regent site signing in with this Privy app; nil until they set one.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:privy_user_id]

  @impl true
  def calculate(accounts, _opts, _context) do
    # Every profile names its Privy app, so a boot with no app configured (the
    # test suite) has no names to read.
    app_ids = List.wrap(Autolaunch.Privy.app_id())
    people = Enum.map(accounts, & &1.privy_user_id)

    # Names are public, so they are read whoever asks; only the name leaves.
    Autolaunch.Accounts.SharedProfile
    |> Ash.Query.filter(app_id in ^app_ids and privy_user_id in ^people)
    |> Ash.Query.select([:privy_user_id, :display_name])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, profiles} ->
        names = Map.new(profiles, &{&1.privy_user_id, &1.display_name})
        {:ok, Enum.map(accounts, &names[&1.privy_user_id])}

      {:error, error} ->
        {:error, error}
    end
  end
end
