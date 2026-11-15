defmodule Autolaunch.CoveredCalls.Sale do
  @moduledoc """
  One covered call changing hands on a market's contract, saved by
  `Autolaunch.CoveredCalls.Sales` from its log, exactly as the chain gave it:

    * `:filled`: a buyer bought calls from a listing (`Filled`). The buyer is
      the wallet the log names, the one that called `fill`; the seller is the
      listing's.
    * `:sold_to_bid`: a seller sold calls into a standing bid (`SoldToBid`),
      which opened listing `listing_id` held by the bidder. The seller is the
      wallet the log names, the one that called `sellToBid`; the buyer is the
      bid's bidder.

  A listing or bid nobody has bought from or sold into is no sale and is not
  saved. Amounts are raw units: the stock's for `amount`, USDC's for `premium`
  (what the buyer paid) and `fee` (the part of it the seller did not get).

  A row is written once and never changed: the same log read again must match
  it, or the action is refused with `Autolaunch.CoveredCalls.Diverged` and the
  reader stops its contract.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.CoveredCalls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls.Diverged

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/
  @facts [
    :chain_id,
    :contract,
    :stock,
    :event,
    :listing_id,
    :bid_id,
    :seller,
    :buyer,
    :amount,
    :premium,
    :fee,
    :transaction_hash,
    :log_index,
    :block_number,
    :block_hash,
    :occurred_at
  ]

  postgres do
    table "covered_call_sales"
    repo Autolaunch.Repo
  end

  actions do
    # One sale, for the site's own check of it (`Autolaunch.Points.CoveredCall`).
    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    # The sales already saved from one contract's blocks `from` to `to`, which
    # the reader checks against the chain as it reads them again.
    read :in_blocks do
      argument :chain_id, :integer, allow_nil?: false
      argument :contract, :string, allow_nil?: false
      argument :from, :integer, allow_nil?: false
      argument :to, :integer, allow_nil?: false

      filter expr(
               chain_id == ^arg(:chain_id) and contract == ^arg(:contract) and
                 block_number >= ^arg(:from) and block_number <= ^arg(:to)
             )
    end

    create :record do
      accept @facts
      upsert? true
      upsert_identity :chain_log
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true

      emit Autolaunch.Signals, :covered_call_recorded,
        dynamic?: true,
        description: "Only when this write saved the sale."

      # A sale already saved skips the upsert and comes back as it was saved,
      # which the log read again must match.
      change after_action(fn changeset, sale, _context ->
               cond do
                 Ash.Resource.get_metadata(sale, :upsert_action) == :insert ->
                   with :ok <-
                          Ash.Signals.emit(
                            changeset,
                            Autolaunch.Signals,
                            :covered_call_recorded,
                            %{sale_id: sale.id}
                          ),
                        do: {:ok, sale}

                 Enum.all?(
                   @facts,
                   &same?(Map.get(sale, &1), Ash.Changeset.get_attribute(changeset, &1))
                 ) ->
                   {:ok, sale}

                 true ->
                   {:error, Diverged.exception(block: sale.block_number)}
               end
             end)
    end
  end

  policies do
    policy action([:by_id, :in_blocks, :record]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]
    # The market's covered-calls contract, and the stock its calls are on.
    attribute :contract, :string, allow_nil?: false, constraints: [match: @address]
    attribute :stock, :string, allow_nil?: false, constraints: [match: @address]
    attribute :event, :atom, allow_nil?: false, constraints: [one_of: [:filled, :sold_to_bid]]
    attribute :listing_id, :integer, allow_nil?: false, constraints: [min: 1]
    # The bid sold into, for `:sold_to_bid` only.
    attribute :bid_id, :integer, constraints: [min: 1]
    attribute :seller, :string, allow_nil?: false, constraints: [match: @address]
    attribute :buyer, :string, allow_nil?: false, constraints: [match: @address]
    attribute :amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :premium, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :fee, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :transaction_hash, :string, allow_nil?: false, constraints: [match: @hash]
    attribute :log_index, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :block_number, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :block_hash, :string, allow_nil?: false, constraints: [match: @hash]
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :chain_log, [:chain_id, :transaction_hash, :log_index]
  end

  defp same?(%Decimal{} = saved, %Decimal{} = read), do: Decimal.equal?(saved, read)
  defp same?(%DateTime{} = saved, %DateTime{} = read), do: DateTime.compare(saved, read) == :eq
  defp same?(saved, read), do: saved == read
end
