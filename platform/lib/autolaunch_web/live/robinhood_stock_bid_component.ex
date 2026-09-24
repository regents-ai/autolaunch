defmodule AutolaunchWeb.RobinhoodStockBidComponent do
  @moduledoc """
  The wallet step of a USDG bid on a Robinhood memestock auction: one review,
  then at most two transactions (the exact USDG allowance when one is needed,
  then the bid itself).

  The wallet Privy has selected drives everything here and its address is proved
  against the mounted lease before anything is read. Nothing is stored: the
  review lives on this page only, the browser reports a hash and stops, and
  every outcome on screen is the server's own read of that hash. A wallet's
  bids are the auction's own records. Once the auction has ended, the page
  passes what that means for bidders and the card keeps only the wallet's
  bids and their settlement.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.AuctionBook
  alias Autolaunch.Robinhood.{Lab, StockBidActions}
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.Components.AuctionBook, as: Book
  alias AutolaunchWeb.UsdValue

  @copy %{
    authentication_required: "Sign in to bid from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    invalid_block_header: "Robinhood gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "Robinhood changed while this was prepared. Try again.",
    robinhood_unavailable: "Robinhood auctions are not open on this site.",
    invalid_auction: "This is not an auction address.",
    unknown_auction: "No Robinhood auction was found at this address.",
    amount_required: "Enter a USDG amount above zero.",
    invalid_amount: "Enter a USDG amount above zero.",
    amount_not_representable: "USDG amounts have at most 6 decimal places.",
    amount_above_balance: "This wallet holds less USDG than that.",
    max_price_required: "Enter a maximum price above zero.",
    invalid_decimal: "Enter the amount and the maximum price as plain numbers above zero.",
    price_below_admissible_tick:
      "Your maximum price is too low. Set it above the auction's current price.",
    price_out_of_range: "This maximum price cannot be used. Try a different one.",
    bid_preparation_unavailable:
      "This maximum price cannot be used. Set it above the auction's current price.",
    usdg_route_unavailable: "USDG cannot be converted for this auction right now.",
    stock_route_unavailable: "USDG cannot be converted for this auction right now.",
    quote_out_of_range: "USDG cannot be converted for this auction right now.",
    stock_not_listed: "This auction's stock is not one this site lists.",
    envelope_invalid: "This review is out of date. Review the bid again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]
  @steps %{"usdg_approval" => :usdg_approval, "usdg_bid" => :usdg_bid}

  @impl true
  def update(%{refresh_bids: true}, socket), do: {:ok, with_reading(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:ended, fn -> nil end)
     |> assign_new(:stake_path, fn -> nil end)
     |> assign_new(:token_symbol, fn -> "tokens" end)
     |> assign_new(:book, fn -> nil end)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:review, fn -> nil end)
     |> assign_new(:sent, fn -> %{} end)
     |> assign_new(:reading, fn -> nil end)
     |> assign_new(:usdg_amount, fn -> Map.get(assigns, :preset_amount) || "" end)
     |> assign_new(:max_price, fn -> "" end)
     |> assign_usd_prices()}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :usd_rate,
        UsdValue.stock_rate(assigns.usd_prices.result, reading_symbol(assigns.reading))
      )

    ~H"""
    <section
      id={@id}
      class="bid-panel rg-panel rg-panel--surface"
      phx-hook="AutolaunchReviewedSteps"
      phx-target={@myself}
    >
      <header class="bid-heading">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label">
            {if @ended, do: "Bidding has ended", else: "Place a bid"}
          </h2>
        </Regent.Structure.section_bar>
        <p :if={@ended}>{@ended}</p>
        <p :if={!@ended}>
          Bid with USDG. It is converted into the auction's stock inside the bid, and any unspent part comes straight back. Your wallet confirms every step.
        </p>
      </header>

      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          {if @ended, do: "Sign in to see your bids", else: "Sign in to bid"}
        </Regent.Primitives.button>
      </p>

      <div :if={@authenticated && !@wallet} class="bid-empty">
        <p>
          {if @ended,
            do: "Choose the wallet you bid from.",
            else: "Choose the wallet you want to bid from."}
        </p>
        <Regent.Primitives.button type="button" data-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div :if={@authenticated && @wallet} class="bid-body">
        <dl class="bid-wallet">
          <div>
            <dt>Wallet</dt>
            <dd class="bid-mono">{short(@wallet)}</dd>
          </div>
          <div :if={@reading}>
            <dt>Auction currency</dt>
            <dd>{@reading.stock["symbol"]}</dd>
          </div>
          <div :if={@reading}>
            <dt>Bidding</dt>
            <dd>{window_copy(@reading)}</dd>
          </div>
        </dl>

        <p :if={@ended && @reading && @reading.bids == []} class="bid-empty">
          This wallet placed no bids on this auction.
        </p>

        <form
          :if={!@ended && !@review}
          id={"#{@id}-form"}
          class="rg-field"
          phx-change="bid_form_changed"
          phx-submit="review_bid"
          phx-target={@myself}
          aria-label="Bid with USDG"
        >
          <label for={"#{@id}-amount"}>Amount in USDG</label>
          <input
            id={"#{@id}-amount"}
            name="usdg_amount"
            value={@usdg_amount}
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
          />
          <label for={"#{@id}-max-price"}>
            Maximum price in {stock_symbol(@reading)} per token
          </label>
          <input
            id={"#{@id}-max-price"}
            name="max_price"
            value={@max_price}
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
          />
          <UsdValue.usd
            :if={@max_price != ""}
            class="bid-usd"
            amount={@max_price}
            rate={@usd_rate}
            per="per token"
          />
          <.standing_line
            outlook={@book && AuctionBook.outlook("", @max_price, @book)}
            book={@book}
            symbol={stock_symbol(@reading)}
          />
          <Regent.Primitives.button class="bid-primary" type="submit">
            Review bid
          </Regent.Primitives.button>
        </form>

        <section
          :if={@review}
          id={"#{@id}-review"}
          class="launch-wallet-review"
          aria-label="Bid review"
        >
          <h3>Review this bid</h3>
          <dl>
            <div :for={row <- @review.review}>
              <dt>{row.label}</dt>
              <dd>
                {row.value}
                <UsdValue.usd :if={row.worth} amount={row.worth} rate={@usd_rate} per={row.per} />
              </dd>
            </div>
            <div>
              <dt>Wallet</dt>
              <dd class="launch-wallet-mono">{short(@review.envelope["expected_signer"])}</dd>
            </div>
            <div>
              <dt>Network</dt>
              <dd>
                {Lab.network_name(@review.envelope["chain_id"])} · chain {@review.envelope["chain_id"]}
              </dd>
            </div>
            <div>
              <dt>Transactions</dt>
              <dd>{step_count(@review.steps)}</dd>
            </div>
          </dl>

          <p class="launch-wallet-risk">{@review.envelope["risk_copy"]}</p>

          <ol class="launch-wallet-steps" role="list" aria-label="Bid progress">
            <li :for={step <- @review.steps} data-step={step["step"]}>
              <span>{step_label(step["step"])}</span>
              <span class="launch-wallet-step-state">{step_state(@sent[step["step"]])}</span>
              <span
                :if={@sent[step["step"]]}
                class="launch-wallet-mono"
                data-local-transaction-hash
              >
                {short_hash(@sent[step["step"]].hash)}
              </span>
            </li>
          </ol>

          <p :if={placed?(@sent)} class="launch-wallet-settled" role="status">
            Your bid was placed and the auction's record of it was verified.
            <span :if={Lab.test_chain?(@review.envelope["chain_id"])}>Test assets have no real value.</span>
          </p>

          <Regent.Primitives.disclosure
            id={"#{@id}-exact-values"}
            summary="Exact values"
            class="launch-wallet-details"
          >
            <dl>
              <div :for={{label, value} <- exact_values(@review)}>
                <dt>{label}</dt>
                <dd class="launch-wallet-mono">{value}</dd>
              </div>
            </dl>
          </Regent.Primitives.disclosure>

          <div class="launch-wallet-controls">
            <Regent.Primitives.button
              :for={step <- @review.steps}
              :if={!placed?(@sent)}
              type="button"
              data-reviewed-step={step["step"]}
              variant={
                if step["step"] == next_step(@review.steps, @sent), do: "primary", else: "secondary"
              }
            >
              {step_label(step["step"])}
            </Regent.Primitives.button>
            <Regent.Primitives.button
              :for={{name, %{outcome: :pending}} <- @sent}
              type="button"
              phx-click="check_step"
              phx-value-step={name}
              phx-target={@myself}
              variant="secondary"
            >
              Check again
            </Regent.Primitives.button>
            <Regent.Primitives.button
              type="button"
              phx-click="clear_review"
              phx-target={@myself}
              variant="secondary"
            >
              {if placed?(@sent), do: "Done", else: "Start over"}
            </Regent.Primitives.button>
          </div>
        </section>

        <section
          :if={@reading && @reading.bids != []}
          class="launch-wallet-settled"
          aria-label="Your bids"
        >
          <h3>Your bids on this auction</h3>
          <ul role="list">
            <li :for={bid <- @reading.bids}>
              <p>
                Bid #{bid["bid_id"]} · {bid["stock_committed_units"]} {@reading.stock["symbol"]}
                <UsdValue.usd amount={bid["stock_committed_units"]} rate={@usd_rate} />
                · {bid_state(bid, @book, @reading)}
              </p>
              <.live_component
                module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
                id={"#{@id}-settle-#{bid["bid_id"]}"}
                parent_id={@id}
                auction={@auction}
                bid={bid}
                graduated?={@reading.graduated?}
                stake_path={@stake_path}
                token_symbol={@token_symbol}
                usd_rate={@usd_rate}
                wallet={@wallet}
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("bid_form_changed", params, socket),
    do: {:noreply, assign(socket, form_values(params))}

  def handle_event("review_bid", params, socket) do
    socket = assign(socket, form_values(params))

    request = %{
      auction: socket.assigns.auction,
      usdg_amount: socket.assigns.usdg_amount,
      max_price: socket.assigns.max_price
    }

    case StockBidActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply, socket |> assign(review: review, sent: %{}, notice: nil) |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: notice(:error, refusal(error)))}
    end
  end

  # The price to beat, entered from the auction's price panel.
  def handle_event("use_price", %{"price" => price}, socket),
    do: {:noreply, assign(socket, max_price: price, notice: nil)}

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, checked(socket, name, hash)}

  def handle_event("check_step", %{"step" => name}, socket) do
    case socket.assigns.sent[name] do
      %{hash: hash} -> {:noreply, checked(socket, name, hash)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

  # "Start over" keeps the entered amounts to adjust; a placed bid starts a fresh form.
  def handle_event("clear_review", _params, socket) do
    {:noreply,
     socket
     |> assign(if placed?(socket.assigns.sent), do: [usdg_amount: "", max_price: ""], else: [])
     |> assign(review: nil, sent: %{}, notice: nil)
     |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  defp form_values(params) do
    [
      usdg_amount: params |> Map.get("usdg_amount", "") |> String.trim(),
      max_price: params |> Map.get("max_price", "") |> String.trim()
    ]
  end

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    case StockBidActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket)) do
      {:ok, %{outcome: outcome}} ->
        socket
        |> assign(
          sent: Map.put(socket.assigns.sent, name, %{hash: hash, outcome: outcome}),
          notice: outcome_notice(outcome)
        )
        |> listed(outcome)

      {:error, error} ->
        assign(socket, notice: notice(:error, refusal(error)))
    end
  end

  defp checked(socket, _name, _hash), do: socket

  defp listed(socket, :confirmed), do: with_reading(socket)
  defp listed(socket, _outcome), do: socket

  defp published(%{assigns: %{review: %{envelope: envelope, steps: steps}}} = socket) do
    push_event(socket, "reviewed-steps:review", %{
      component_id: socket.assigns.id,
      signer: envelope["expected_signer"],
      chain_id: envelope["chain_id"],
      lab: envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: envelope["arguments"]["block_number"],
        block_hash: envelope["arguments"]["block_hash"]
      },
      steps: Enum.map(steps, &Map.take(&1, ["step", "to", "data"]))
    })
  end

  # A visitor who is not signed in is asked to sign in, not read for.
  defp adopt(%{assigns: %{authenticated: false}} = socket, _address), do: socket

  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(%{assigns: %{wallet: wallet}} = socket, wallet), do: socket

  defp adopt(socket, address) do
    case StockBidActions.bids(socket.assigns.auction, address, opts(socket)) do
      {:ok, reading} ->
        socket
        |> assign(wallet: String.downcase(address), reading: reading, notice: nil)
        |> reviewed_for_wallet()

      {:error, error} ->
        refused(socket, address, refusal(error))
    end
  end

  # A review belongs to the wallet it was prepared for; another wallet starts clean.
  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet,
      do: socket,
      else:
        socket
        |> assign(review: nil, sent: %{})
        |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp reviewed_for_wallet(socket), do: socket

  defp with_reading(socket) do
    case StockBidActions.bids(socket.assigns.auction, socket.assigns.wallet, opts(socket)) do
      {:ok, reading} -> assign(socket, reading: reading)
      {:error, _unavailable} -> socket
    end
  end

  # Any wallet but the signed-in one is not adopted at all; the signed-in one
  # stays on screen with the reason.
  defp refused(socket, _address, reason) when reason in @unheld do
    assign(socket,
      wallet: nil,
      review: nil,
      sent: %{},
      reading: nil,
      notice: notice(:error, reason)
    )
  end

  defp refused(socket, address, reason) do
    assign(socket,
      wallet: String.downcase(address),
      reading: nil,
      notice: notice(:info, reason)
    )
  end

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp placed?(sent), do: match?(%{outcome: :confirmed}, sent["usdg_bid"])

  defp next_step(steps, sent) do
    Enum.find_value(steps, fn %{"step" => name} ->
      if match?(%{outcome: :confirmed}, sent[name]), do: nil, else: name
    end)
  end

  defp step_count([_one]), do: "One transaction"
  defp step_count([_one, _two]), do: "Two transactions"

  defp step_label("usdg_approval"), do: "Allow this USDG to be spent"
  defp step_label("usdg_bid"), do: "Place the bid"

  defp step_state(nil), do: "Ready"
  defp step_state(%{outcome: :pending}), do: "Sent"
  defp step_state(%{outcome: :confirmed}), do: "Verified"
  defp step_state(%{outcome: :reverted}), do: "Reverted"
  defp step_state(%{outcome: :unverified}), do: "Unresolved"

  defp outcome_notice(:pending),
    do: %{tone: :info, message: "Sent. Waiting for Robinhood to include it."}

  defp outcome_notice(:confirmed), do: nil

  defp outcome_notice(:reverted),
    do: %{tone: :error, message: "That transaction reverted. No bid was placed by it."}

  defp outcome_notice(:unverified),
    do: %{tone: :error, message: "That transaction did not record the step you reviewed."}

  # Robinhood's stock prices, read once and apart from the form, so a slow
  # price never holds a bid back.
  defp assign_usd_prices(%{assigns: %{usd_prices: _prices}} = socket), do: socket

  defp assign_usd_prices(socket),
    do:
      UsdValue.assign_rate(socket, :usd_prices, :robinhood, fn ->
        {:ok, %{usd_prices: MarketData.prices(:robinhood)}}
      end)

  defp reading_symbol(%{stock: %{"symbol" => symbol}}), do: symbol
  defp reading_symbol(nil), do: nil

  defp stock_symbol(%{stock: %{"symbol" => symbol}}), do: symbol
  defp stock_symbol(nil), do: "the auction's stock"

  defp window_copy(%{clock: now, window: %{"start_block" => start_block}})
       when now < start_block,
       do: "Opens at block #{start_block}. Robinhood is at block #{now}."

  defp window_copy(%{clock: now, window: %{"end_block" => end_block}})
       when now < end_block,
       do: "Open until block #{end_block}. Robinhood is at block #{now}."

  defp window_copy(_reading), do: "Ended."

  defp bid_state(%{"exited_block" => block, "tokens_filled_now" => filled}, _book, _reading)
       when block != "0" do
    if filled != "0", do: "Bid settled · tokens allocated", else: "Bid settled"
  end

  # Reaching the minimum mid-auction does not make a bid a winner yet.
  defp bid_state(%{"exited_block" => "0", "max_price_q96" => price}, book, %{
         graduated?: true,
         clock: clock,
         window: %{"end_block" => end_block}
       })
       when clock >= end_block and not is_nil(book),
       do:
         price |> String.to_integer() |> AuctionBook.standing(book) |> Book.graduated_bid_status()

  defp bid_state(_bid, _book, %{clock: clock, window: %{"end_block" => end_block}})
       when clock >= end_block, do: "Bidding ended · review your return and token allocation"

  defp bid_state(%{"exited_block" => "0"}, nil, _reading), do: "In the auction"

  defp bid_state(%{"exited_block" => "0", "max_price_q96" => price}, book, _reading),
    do: price |> String.to_integer() |> AuctionBook.standing(book) |> Book.bid_status()

  defp bid_state(%{"exited_block" => block}, _book, _reading), do: "Exited at block #{block}"

  attr :outlook, :map, default: nil
  attr :book, :map, default: nil
  attr :symbol, :string, required: true

  # Whether the typed maximum buys against the auction's price now.
  defp standing_line(%{outlook: %{reaches?: true}} = assigns) do
    ~H"""
    <p class="bid-estimate" role="status">
      Above the price now: your bid starts buying next block.
    </p>
    """
  end

  defp standing_line(%{outlook: %{reaches?: false}} = assigns) do
    ~H"""
    <p class="bid-estimate" role="status">
      Too low to buy right now: bid at least {@book.price_to_beat} {@symbol} per token.
    </p>
    """
  end

  defp standing_line(assigns), do: ~H""

  defp exact_values(review) do
    [
      {"Auction", argument(review, "auction")},
      {"Stock", argument(review, "stock")},
      {"Bid contract", argument(review, "adapter")},
      {"USDG", argument(review, "usdg")},
      {"Stock route", argument(review, "route")},
      {"USDG spent at most (base units)", argument(review, "usdg_amount_atomic")},
      {"Lowest stock accepted (base units)", argument(review, "min_stock_out_atomic")},
      {"Max price (Q96)", argument(review, "max_price_q96")},
      {"Deadline (Unix seconds)", argument(review, "deadline")},
      {"Reviewed block",
       "#{argument(review, "block_number")} · #{argument(review, "block_hash")}"},
      {"Calldata digest", review.envelope["metadata"]["calldata_sha256"]}
    ]
  end

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under the reviewed chain number. Check the network settings in your wallet, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
