defmodule Autolaunch.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that made it, so
  something that rolls back offers nothing. Points decides whether it earns;
  while a rule is off nothing is queued.

    * A Credits purchase credited to an account, or a waiting one an account
      now holds (`credits.purchase_settled`), from `RegentCredits.Signals`.
      Credits is one Regents ledger, so every site names it "regents" and a
      purchase earns once.
    * A new Regent account (`account.activated`), from
      `Autolaunch.Accounts.Signals`. The account is one Regents account on
      every site, so it is named "regents" too.
    * A social account linked to an account (`social.x`, `social.github`,
      `social.farcaster`), from `Autolaunch.Accounts.Signals`, keyed by the
      provider and its subject so one social account earns once.
    * An agent paired with its person (`agent.activated`), from
      `RegentAgents.Signals`, keyed by the pairing.
    * An auction listed for the account whose review carried out its launch
      (`autolaunch.auction_created`), and its graduation
      (`autolaunch.first_graduation`), from `Autolaunch.Signals`, keyed by the
      auction.
    * A confirmed bid (`autolaunch.auction_bid`), and a bid's confirmed
      withdraw or claim (`autolaunch.first_settled_auction`), from a wallet
      that belonged to an account or its paired agent when it acted, from
      `Autolaunch.Signals`, keyed by the auction and the bid.
    * A stake in a launch's splitter (`autolaunch.token_staked`) from a
      wallet that belonged to an account or its paired agent when it staked,
      keyed by the token, the transaction and the log.
    * A swap sent from the site's trade panel (`autolaunch.token_traded`),
      keyed by its saved record (`Autolaunch.SiteTrade`).
  """

  use Ash.Resource,
    domain: Autolaunch.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.Actors.System

  actions do
    action :account_registered do
      argument :signal, Autolaunch.Accounts.Signals.AccountRegistered, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("account.activated", "account", to_string(signal.account_id), "regents")
      end
    end

    action :social_linked do
      argument :signal, Autolaunch.Accounts.Signals.SocialLinked, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record(
          "social.#{signal.provider}",
          "linked_identity",
          "#{signal.provider}:#{signal.subject}"
        )
      end
    end

    action :agent_paired do
      argument :signal, RegentAgents.Signals.AgentPaired, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("agent.activated", "pairing", signal.paired_agent_id)
      end
    end

    action :launch_listed do
      argument :signal, Autolaunch.Signals.LaunchListed, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("autolaunch.auction_created", "auction", signal.auction_id)
      end
    end

    action :launch_graduated do
      argument :signal, Autolaunch.Signals.LaunchGraduated, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("autolaunch.first_graduation", "graduation", signal.auction_id)
      end
    end

    action :bid_recorded do
      argument :signal, Autolaunch.Signals.BidRecorded, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("autolaunch.auction_bid", "bid", "#{signal.auction_id}:#{signal.bid_id}")
      end
    end

    action :bid_settled do
      argument :signal, Autolaunch.Signals.BidSettled, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        key = "#{signal.auction_id}:#{signal.bid_id}:#{signal.kind}"
        record("autolaunch.first_settled_auction", "settlement", key)
      end
    end

    action :token_staked do
      argument :signal, Autolaunch.Signals.TokenStaked, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        key = "#{signal.token_id}:#{signal.transaction_hash}:#{signal.log_index}"
        record("autolaunch.token_staked", "stake", key)
      end
    end

    action :trade_reported do
      argument :signal, Autolaunch.Signals.TradeReported, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("autolaunch.token_traded", "trade", signal.site_trade_id)
      end
    end

    action :credits_purchase do
      argument :signal, :struct, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("credits.purchase_settled", "credits_purchase", signal.purchase_id, "regents")
      end
    end
  end

  policies do
    # Reached only through the signals above, after the action that emitted
    # them was allowed; each records as the system, never as the actor.
    policy always() do
      authorize_if always()
    end
  end

  signals_in do
    from Autolaunch.Accounts.Signals do
      on :account_registered, :account_registered
      on :social_linked, :social_linked
    end

    from RegentAgents.Signals do
      on :agent_paired, :agent_paired
    end

    from Autolaunch.Signals do
      on :launch_listed, :launch_listed
      on :launch_graduated, :launch_graduated
      on :bid_recorded, :bid_recorded
      on :bid_settled, :bid_settled
      on :token_staked, :token_staked
      on :trade_reported, :trade_reported
    end

    from RegentCredits.Signals do
      on :purchase_credited, :purchase_credited, action: :credits_purchase
      on :purchase_attributed, :purchase_attributed, action: :credits_purchase
    end
  end

  defp record(rule_id, kind, key, app \\ "autolaunch") do
    reference = %{rule_id: rule_id, source_app: app, source_kind: kind, source_event_key: key}
    with {:ok, _event} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
  end
end
