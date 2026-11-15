defmodule Autolaunch.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that saved it, so
  something that rolls back offers nothing. Points decides whether it earns;
  while a rule is off nothing is queued and nothing is written.

    * A launch the site saved (`autolaunch.first_launch`, once per account, and
      `autolaunch.auction_created`, once a day), from `:launch_recorded`, keyed
      by the launch's auction row (`Autolaunch.Points.Launch`).
    * A launch's token saved once it graduated (`autolaunch.first_graduation`,
      once per account), from `:token_graduated`, keyed by the token row
      (`Autolaunch.Points.Graduation`).
  """

  use Ash.Resource,
    domain: Autolaunch.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.Actors.System

  actions do
    action :launch_recorded do
      argument :signal, Autolaunch.Signals.LaunchRecorded, allow_nil?: false

      run fn %{arguments: %{signal: %{auction_id: id}}}, _context ->
        with :ok <- record("autolaunch.first_launch", "auction", id),
             do: record("autolaunch.auction_created", "auction", id)
      end
    end

    action :token_graduated do
      argument :signal, Autolaunch.Signals.TokenGraduated, allow_nil?: false

      run fn %{arguments: %{signal: %{token_id: id}}}, _context ->
        record("autolaunch.first_graduation", "token", id)
      end
    end
  end

  policies do
    # Reached only through the signals above, after the write that emitted them
    # was allowed; each records as the system, never as the actor.
    policy action(:launch_recorded) do
      authorize_if signal_in(Autolaunch.Signals, :launch_recorded)
    end

    policy action(:token_graduated) do
      authorize_if signal_in(Autolaunch.Signals, :token_graduated)
    end
  end

  signals_in do
    from Autolaunch.Signals do
      on :launch_recorded, :launch_recorded
      on :token_graduated, :token_graduated
    end
  end

  defp record(rule_id, source_kind, key) do
    reference = %{
      rule_id: rule_id,
      source_app: Autolaunch.Points.source_app(),
      source_kind: source_kind,
      source_event_key: key
    }

    with {:ok, _queued} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
  end
end
