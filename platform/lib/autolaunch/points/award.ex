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
    * A Base bid saved as its bidder's position (`autolaunch.auction_bid`, once
      a day), from `:bid_recorded`, keyed by the position row
      (`Autolaunch.Points.Bid`).
    * A trade saved in a listed token's pool (`autolaunch.token_traded`, once a
      day), from `:trade_recorded`, keyed by the pool log it came from
      (`Autolaunch.Points.Trade`).
    * A stake saved in a launch's splitter (`autolaunch.token_staked`, once
      per account), from `:stake_recorded`, keyed by the stake row
      (`Autolaunch.Points.Stake`).
    * A covered call that changed hands (`autolaunch.first_covered_call`, once
      per account, for its seller and for its buyer), from
      `:covered_call_recorded`, keyed by the sale row, once as the seller's
      and once as the buyer's (`Autolaunch.Points.CoveredCall`).

  The account rules every Regent site offers, from `Autolaunch.Accounts.Signals`
  and `RegentAgents.Signals`:

    * A new Regent account (`account.activated`), from `:account_registered`.
      The account is one Regents account on every site, so every site names it
      "regents" and it earns once (`Autolaunch.Points.AccountActivated`).
    * A GitHub or Farcaster account linked at sign-in (`social.github`,
      `social.farcaster`), from `:social_linked`, keyed by the provider and its
      subject so one social account earns once (`Autolaunch.Points.LinkedSocial`).
      An X account Privy lists offers nothing here.
    * An X account connected as the person's own with the Account page's X
      button (`social.x`), from `:x_connected`, keyed by the X account's user
      id so one X account earns once; a company connection offers nothing
      (`Autolaunch.Points.ConnectedX`).
    * An agent paired with its person (`agent.activated`), from
      `:agent_paired`, keyed by the pairing (`Autolaunch.Points.PairedAgent`).
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

    action :bid_recorded do
      argument :signal, Autolaunch.Signals.BidRecorded, allow_nil?: false

      run fn %{arguments: %{signal: %{position_id: id}}}, _context ->
        record("autolaunch.auction_bid", "bid", id)
      end
    end

    action :trade_recorded do
      argument :signal, Autolaunch.Signals.TradeRecorded, allow_nil?: false

      run fn %{arguments: %{signal: trade}}, _context ->
        record("autolaunch.token_traded", "trade", Autolaunch.Points.Trade.key(trade))
      end
    end

    action :stake_recorded do
      argument :signal, Autolaunch.Signals.StakeRecorded, allow_nil?: false

      run fn %{arguments: %{signal: %{stake_id: id}}}, _context ->
        record("autolaunch.token_staked", "stake", id)
      end
    end

    # Each side of the sale under its own source, so the seller and the buyer
    # can each earn it, and an account on both sides earns it once.
    action :covered_call_recorded do
      argument :signal, Autolaunch.Signals.CoveredCallRecorded, allow_nil?: false

      run fn %{arguments: %{signal: %{sale_id: id}}}, _context ->
        with :ok <- record("autolaunch.first_covered_call", "covered_call_seller", id),
             do: record("autolaunch.first_covered_call", "covered_call_buyer", id)
      end
    end

    action :account_registered do
      argument :signal, Autolaunch.Accounts.Signals.AccountRegistered, allow_nil?: false

      run fn %{arguments: %{signal: %{account_id: id}}}, _context ->
        record(%{
          rule_id: "account.activated",
          source_app: "regents",
          source_kind: "account",
          source_event_key: to_string(id)
        })
      end
    end

    # An X account earns from the X button's connection (:x_connected), so a
    # link Privy lists for X offers nothing.
    action :social_linked do
      argument :signal, Autolaunch.Accounts.Signals.SocialLinked, allow_nil?: false

      run fn
        %{arguments: %{signal: %{provider: :x}}}, _context ->
          :ok

        %{arguments: %{signal: %{provider: provider, subject: subject}}}, _context ->
          record("social.#{provider}", "linked_identity", "#{provider}:#{subject}")
      end
    end

    # Only the person's own X earns; a company connection offers nothing.
    action :x_connected do
      argument :signal, Autolaunch.Accounts.Signals.XConnected, allow_nil?: false

      run fn
        %{arguments: %{signal: %{role: :profile, x_user_id: x_user_id}}}, _context ->
          record("social.x", "x_connection", "x:" <> x_user_id)

        %{arguments: %{signal: %{role: :company}}}, _context ->
          :ok
      end
    end

    action :agent_paired do
      argument :signal, RegentAgents.Signals.AgentPaired, allow_nil?: false

      run fn %{arguments: %{signal: %{paired_agent_id: id}}}, _context ->
        record("agent.activated", "pairing", id)
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

    policy action(:bid_recorded) do
      authorize_if signal_in(Autolaunch.Signals, :bid_recorded)
    end

    policy action(:trade_recorded) do
      authorize_if signal_in(Autolaunch.Signals, :trade_recorded)
    end

    policy action(:stake_recorded) do
      authorize_if signal_in(Autolaunch.Signals, :stake_recorded)
    end

    policy action(:covered_call_recorded) do
      authorize_if signal_in(Autolaunch.Signals, :covered_call_recorded)
    end

    policy action(:account_registered) do
      authorize_if signal_in(Autolaunch.Accounts.Signals, :account_registered)
    end

    policy action(:social_linked) do
      authorize_if signal_in(Autolaunch.Accounts.Signals, :social_linked)
    end

    policy action(:x_connected) do
      authorize_if signal_in(Autolaunch.Accounts.Signals, :x_connected)
    end

    policy action(:agent_paired) do
      authorize_if signal_in(RegentAgents.Signals, :agent_paired)
    end
  end

  signals_in do
    from Autolaunch.Signals do
      on :launch_recorded, :launch_recorded
      on :token_graduated, :token_graduated
      on :bid_recorded, :bid_recorded
      on :trade_recorded, :trade_recorded
      on :stake_recorded, :stake_recorded
      on :covered_call_recorded, :covered_call_recorded
    end

    from Autolaunch.Accounts.Signals do
      on :account_registered, :account_registered
      on :social_linked, :social_linked
      on :x_connected, :x_connected
    end

    from RegentAgents.Signals do
      on :agent_paired, :agent_paired
    end
  end

  # This site's own source of the rule.
  defp record(rule_id, source_kind, key) do
    record(%{
      rule_id: rule_id,
      source_app: Autolaunch.Points.source_app(),
      source_kind: source_kind,
      source_event_key: key
    })
  end

  defp record(reference) do
    with {:ok, _queued} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
  end
end
