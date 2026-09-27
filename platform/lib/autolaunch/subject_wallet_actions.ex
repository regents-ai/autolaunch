defmodule Autolaunch.SubjectWalletActions do
  @moduledoc """
  The one boundary between a subject's wallet and Base.

  Preparation reads Base once, proves the stored splitter and canonical receiver
  really are this launch's own, and returns the review's chain, its steps (an
  exact approval when one is missing, then the payment or the sweep) and the
  facts the page shows. The page keeps it; nothing is stored. `result/2` reads
  what a confirmed payment or sweep routed from its receipt.

  The wallet is one of the signed-in account's own, proved against the account
  the mounted lease resolves to before any private fact is read.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, Rpc, SubjectAbi}
  alias Autolaunch.{Lab, Subject, SubjectWalletChainClient}
  alias RegentChain.{Address, Review}

  @chain_id 8453
  @zero "0x0000000000000000000000000000000000000000"

  # The exact 2% every recognized inflow floors once, and the fixed denominator
  # the post-skim net is divided by: the complete SUBJECT supply every authentic
  # launch mints. Current stakers collectively receive the fraction of the net
  # their stake covers of that whole supply; the treasury receives the rest.
  @protocol_share_bps 200
  @bps_denominator 10_000
  @subject_total_supply 100_000_000_000 * Integer.pow(10, 18)

  # Both actions recognize an inflow at the canonical receiver, and so divide one.
  @kinds [:pay, :sweep]
  # The receiver routes every sweep under the zero payment reference.
  @sweep_reference "0x" <> String.duplicate("0", 64)
  @assets [:subject, :usdc, :regent]

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @doc """
  What `address`, one of the signed-in account's wallets, holds on this subject.

  The address is proved against the account the mounted lease resolves to before
  any private fact is read, so a wallet the account does not hold is refused
  rather than answered about.
  """
  @spec wallet_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(subject_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, subject} <- stored_split(subject_id),
         {:ok, snapshot} <- snapshot(subject, signer, nil, nil) do
      {:ok, view(subject, signer, snapshot)}
    end
  end

  @doc """
  Reviews one action for `address`: one snapshot, then the review's signer,
  chain, steps and facts.

  The steps are only the transactions this wallet still needs: an exact token
  approval when one is missing, then the single call it enables.
  """
  @spec prepare(String.t(), String.t(), atom(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(subject_id, address, kind, params, opts) when kind in @kinds do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, config} <- lab(),
         {:ok, subject} <- actionable(subject_id),
         {:ok, asset} <- selected_asset(kind, params),
         {:ok, snapshot} <- snapshot(subject, signer, kind, asset),
         {:ok, plan} <- planned(kind, asset, params, snapshot, signer) do
      {:ok,
       %{
         signer: signer,
         chain: Client.chain(config),
         steps: steps(plan, snapshot, asset),
         facts: facts(subject, kind, asset, plan, snapshot)
       }}
    end
  end

  def prepare(_subject_id, _address, _kind, _params, _opts), do: unavailable(:unknown_action)

  @doc "The exact decimal rendering of an atomic amount of one bound asset."
  @spec units(non_neg_integer() | String.t(), atom()) :: String.t()
  def units(amount, asset) when is_binary(amount),
    do: amount |> String.to_integer() |> units(asset)

  def units(amount, asset), do: Rpc.format_units(amount, SubjectAbi.decimals(asset))

  @doc """
  What a confirmed payment or sweep routed, from its receipt `logs`: the gross
  amount in the reviewed asset's units, or `nil` when its own event is not
  there. A payment has to route exactly the gross it reviewed; a sweep learns
  the amount it really moved.
  """
  @spec result(map(), [map()]) :: String.t() | nil
  def result(%{kind: kind, amount_atomic: reviewed} = facts, logs) do
    case SubjectAbi.payment_routed(logs, facts.receiver, facts.payment_reference, facts.token) do
      {:ok, %{gross: gross}} when kind == :sweep or gross == reviewed ->
        units(gross, facts.asset)

      _not_routed ->
        nil
    end
  end

  # Every rule the plan fixes for one action, answered from the one snapshot.
  defp planned(:pay, asset, params, snapshot, _signer) do
    with {:ok, amount} <- positive_amount(params, asset),
         :ok <- at_most(amount, balance(snapshot, asset), :amount_above_balance) do
      reference = payment_reference()

      {:ok,
       %{
         amount: amount,
         spender: snapshot.receiver.address,
         payment_reference: reference,
         data: SubjectAbi.encode_pay(asset_address(snapshot, asset), amount, reference)
       }}
    end
  end

  # The receiver's own current balance is what a sweep routes, so it is reviewed
  # rather than chosen, and the event supplies the amount that actually moved.
  defp planned(:sweep, asset, _params, snapshot, _signer) do
    held = snapshot.receiver.balances[asset]

    if held > 0 do
      {:ok,
       %{
         amount: held,
         payment_reference: @sweep_reference,
         data: SubjectAbi.encode_sweep(asset_address(snapshot, asset))
       }}
    else
      unavailable(:nothing_to_sweep)
    end
  end

  defp steps(plan, snapshot, asset) do
    approval_step(plan, snapshot, asset) ++
      [Review.step("action", snapshot.receiver.address, plan.data)]
  end

  # What the page shows and what `result/2` reads the receipt against.
  defp facts(subject, kind, asset, plan, snapshot) do
    %{
      subject_id: subject.subject_id,
      kind: kind,
      asset: asset,
      receiver: snapshot.receiver.address,
      token: asset_address(snapshot, asset),
      amount_atomic: plan.amount,
      amount: units(plan.amount, asset),
      payment_reference: plan.payment_reference,
      allocation: allocation(plan, snapshot)
    }
  end

  # Only the approval this wallet still needs. An allowance that already covers
  # the reviewed amount is spent exactly as it stands.
  defp approval_step(%{spender: spender, amount: amount}, snapshot, asset)
       when is_binary(spender) do
    if snapshot.allowance >= amount,
      do: [],
      else: [
        Review.step(
          "approval",
          asset_address(snapshot, asset),
          Abi.encode_erc20("approve", [spender, amount])
        )
      ]
  end

  defp approval_step(_plan, _snapshot, _asset), do: []

  # The exact integer division one recognized inflow makes, floored twice and in
  # atomic units of the reviewed asset: the 2% skim, then the staker allocation
  # the stake covers of the complete SUBJECT supply, then the exact remainder to
  # the treasury. Nothing here is a percentage, an estimate, or a chain read.
  defp allocation(%{amount: gross}, %{splitter: %{total_staked: staked}}) do
    skim = div(gross * @protocol_share_bps, @bps_denominator)
    net = gross - skim
    stakers = div(net * staked, @subject_total_supply)

    %{gross: gross, skim: skim, net: net, stakers: stakers, treasury: net - stakers}
  end

  defp lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:chain_unavailable)
    end
  end

  # Chain snapshot

  defp snapshot(subject, signer, kind, asset) do
    request = %{
      splitter: subject.splitter_address,
      receiver: receiver_request(subject),
      signer: signer,
      token: asset && subject_asset_address(subject, asset),
      spender: spender_request(kind, subject)
    }

    case SubjectWalletChainClient.module().snapshot(request) do
      {:ok, snapshot} -> snapshot |> put_addresses(subject) |> proved(subject, kind)
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # A receiver is read whenever the subject has a projected one, so the page can
  # show the receiver's own balances before any action is chosen.
  defp receiver_request(%{canonical_receiver_address: address}) when is_binary(address),
    do: address

  defp receiver_request(_subject), do: nil

  defp spender_request(:pay, subject), do: subject.canonical_receiver_address
  defp spender_request(_kind, _subject), do: nil

  # Every binding the review depends on, proved against the pinned product
  # authority before a review can exist. The receiver additionally has to
  # be canonical: zero referral, and a treasury that is both its beneficiary and
  # its note editor, which is the whole of the economics the page promises.
  defp proved(snapshot, subject, kind) do
    with :ok <-
           bound(snapshot.splitter.subject, subject.token_address, :splitter_subject_mismatch),
         :ok <- bound(snapshot.splitter.usdc, Abi.usdc_address(), :splitter_usdc_mismatch),
         :ok <-
           bound(snapshot.splitter.regent, Abi.regent_address(), :splitter_regent_mismatch),
         :ok <-
           bound(
             snapshot.splitter.treasury,
             subject.treasury_address,
             :splitter_treasury_mismatch
           ),
         :ok <- canonical_receiver(snapshot, subject, kind) do
      {:ok, snapshot}
    end
  end

  defp canonical_receiver(%{receiver: nil}, _subject, kind) when kind in @kinds,
    do: unavailable(:canonical_receiver_unavailable)

  defp canonical_receiver(%{receiver: nil}, _subject, _kind), do: :ok

  defp canonical_receiver(%{receiver: receiver, splitter: splitter}, subject, _kind) do
    with :ok <- bound(receiver.splitter, splitter.address, :receiver_splitter_mismatch),
         :ok <- bound(receiver.subject, subject.token_address, :receiver_subject_mismatch),
         :ok <- bound(receiver.usdc, Abi.usdc_address(), :receiver_usdc_mismatch),
         :ok <- bound(receiver.regent, Abi.regent_address(), :receiver_regent_mismatch),
         :ok <- bound(receiver.treasury, splitter.treasury, :receiver_treasury_mismatch),
         :ok <- bound(receiver.beneficiary, splitter.treasury, :receiver_not_canonical),
         :ok <- bound(receiver.note_editor, splitter.treasury, :receiver_not_canonical),
         do: zero_referral(receiver)
  end

  defp zero_referral(%{referral_bps: 0}), do: :ok
  defp zero_referral(_referring), do: unavailable(:receiver_not_canonical)

  defp bound(actual, expected, reason) do
    if is_binary(expected) and Address.equal?(actual, expected),
      do: :ok,
      else: unavailable(reason)
  end

  defp put_addresses(snapshot, subject) do
    snapshot
    |> put_in([:splitter, :address], normalized!(subject.splitter_address))
    |> put_receiver_address(subject)
  end

  defp put_receiver_address(%{receiver: nil} = snapshot, _subject), do: snapshot

  defp put_receiver_address(snapshot, subject),
    do: put_in(snapshot, [:receiver, :address], normalized!(subject.canonical_receiver_address))

  # Stored subjects

  defp stored_split(subject_id) do
    with {:ok, subject} <- stored_subject(subject_id),
         :ok <- base_chain(subject),
         :ok <- standard(subject.token_address, :subject_token_unavailable),
         :ok <- standard(subject.splitter_address, :subject_splitter_unavailable),
         :ok <- standard(subject.treasury_address, :subject_treasury_unavailable),
         do: {:ok, subject}
  end

  defp actionable(subject_id) do
    with {:ok, subject} <- stored_split(subject_id),
         :ok <- standard(subject.canonical_receiver_address, :canonical_receiver_unavailable),
         do: {:ok, subject}
  end

  defp stored_subject(subject_id) do
    case Autolaunch.get_public_subject(subject_id, actor: nil) do
      {:ok, nil} -> unavailable(:subject_not_found)
      {:ok, subject} -> {:ok, subject}
      {:error, _reason} -> unavailable(:subject_unavailable)
    end
  end

  defp base_chain(%{chain_id: @chain_id}), do: :ok
  defp base_chain(_other), do: unavailable(:subject_not_on_base)

  defp standard(address, reason) do
    case Address.normalize(address) do
      {:ok, @zero} -> unavailable(reason)
      {:ok, _address} -> :ok
      :error -> unavailable(reason)
    end
  end

  # Assets and amounts

  defp selected_asset(_kind, params) do
    case params["asset"] do
      "subject" -> {:ok, :subject}
      "usdc" -> {:ok, :usdc}
      "regent" -> {:ok, :regent}
      _unsupported -> unavailable(:unsupported_asset)
    end
  end

  defp positive_amount(params, asset), do: params |> Map.get("amount") |> atomic_amount(asset)

  @doc """
  The one amount language for a bound asset: exact digits, at most its decimals.

  The form validates against this, so the page never invites an amount that
  preparation would refuse.
  """
  @spec atomic_amount(term(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def atomic_amount(value, asset) when is_binary(value) do
    decimals = SubjectAbi.decimals(asset)
    value = String.trim(value)

    with true <- String.match?(value, ~r/^\d+(?:\.\d{1,#{decimals}})?$/),
         {decimal, ""} <- Decimal.parse(value),
         scaled <- Decimal.mult(decimal, Decimal.new(Integer.pow(10, decimals))),
         rounded <- Decimal.round(scaled, 0),
         :eq <- Decimal.compare(scaled, rounded),
         amount when amount > 0 <- Decimal.to_integer(rounded) do
      {:ok, amount}
    else
      _refused -> unavailable(:invalid_amount)
    end
  end

  def atomic_amount(_value, _asset), do: unavailable(:invalid_amount)

  defp at_most(amount, limit, _reason) when amount <= limit, do: :ok
  defp at_most(_amount, _limit, reason), do: unavailable(reason)

  # Every payment carries its own cryptographically random reference, so two
  # payments of the same amount are never the same reviewed transaction.
  defp payment_reference,
    do: "0x" <> (32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp balance(snapshot, asset), do: snapshot.balances[asset]

  defp asset_address(snapshot, :subject), do: snapshot.splitter.subject
  defp asset_address(snapshot, :usdc), do: snapshot.splitter.usdc
  defp asset_address(snapshot, :regent), do: snapshot.splitter.regent

  defp subject_asset_address(subject, :subject), do: subject.token_address
  defp subject_asset_address(_subject, :usdc), do: Abi.usdc_address()
  defp subject_asset_address(_subject, :regent), do: Abi.regent_address()

  # The whole private answer for one wallet on one subject.
  defp view(subject, signer, snapshot) do
    %{
      signer: signer,
      subject_id: subject.subject_id,
      balances: Map.new(@assets, &{&1, units(balance(snapshot, &1), &1)}),
      receiver: receiver_view(snapshot)
    }
  end

  defp receiver_view(%{receiver: nil}), do: nil

  defp receiver_view(%{receiver: receiver}) do
    %{
      address: receiver.address,
      balances: Map.new(@assets, &{&1, units(receiver.balances[&1], &1)})
    }
  end

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        unavailable(:session_lease_required)
    end
  end

  # The wallet has to be one the leased account links, read now. A lineage that
  # has been revoked, rebound or whose provider evidence has lapsed resolves to
  # no account.
  defp current_wallet(address, opts) do
    with {:ok, signer} <- normalize(address),
         {:ok, %{lineage: lineage, account_id: account_id}} <- lease(opts),
         do: lineage |> SessionAuthority.leased_account(account_id) |> linked_wallet(signer)
  end

  defp linked_wallet(nil, _signer), do: unavailable(:session_unavailable)

  defp linked_wallet(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets, &Address.equal?(&1, signer)),
      do: {:ok, signer},
      else: unavailable(:wrong_signer)
  end

  # Shared helpers

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp normalized!(value) do
    {:ok, address} = Address.normalize(value)
    address
  end

  defp unavailable(reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: Subject, reason: reason)}
end
