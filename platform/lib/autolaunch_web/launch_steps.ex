defmodule AutolaunchWeb.LaunchSteps do
  @moduledoc """
  What the three launch cards share (`AutolaunchWeb.LaunchWalletComponent`,
  `AutolaunchWeb.StocksLaunchWalletComponent` and
  `AutolaunchWeb.RobinhoodStocksLaunchComponent`): the wallet that may act, the
  one "Create the launch" step of the review on the page, and the lines and
  buttons under it.

  "Review launch" prepares the review on the server for Privy's active wallet
  when the signed-in account links it (`AutolaunchWeb.OnchainSteps`); with no
  active wallet it opens Privy's connect step instead. The review lives on the
  page. The step's button has no server round trip: the `OnchainSteps` hook
  sends it, every press reaches the wallet, and every outcome is the server's
  own read of the hash against the review it was sent from. A review nothing
  was sent from is dropped when another wallet on the account becomes active.

  The review on the page is checked against the chain again once it is ten
  minutes old and once its step reverts (`rechecked/3`), and built again when
  what it was built against has changed.

  The lines above the button stay in the page and are only hidden, so one
  appearing never moves the button a person is pressing.

  Once the page sees its launch confirmed, the review comes off the page, the
  form starts over blank, and the card says the launch is made, with its
  transaction and, once the site has it, its auction page (`launched/4`).
  """

  use Phoenix.Component

  import AutolaunchWeb.Components.StepState
  import Phoenix.LiveView, only: [start_async: 3]

  alias Autolaunch.{LaunchedDrafts, LaunchReviews}
  alias AutolaunchWeb.{AgentPress, OnchainSteps, Paths, Telemetry}
  alias AutolaunchWeb.Components.{BidPlaced, MarketCard, SwapForm}
  alias Phoenix.LiveView.JS
  alias RegentChain.{Presses, Review}

  @reverted "That launch did not go through, so nothing was created. Only the network fee was spent. Press again."
  @rebuilt "That launch did not go through, so nothing was created. Only the network fee was spent. The review now matches the network as it is: press again."

  @launched "Sent. The page shows the launch once the network confirms it, with a link to its auction page, and autolaunch_auctions lists it within a minute."

  # The auction page of a confirmed launch is asked for every two seconds for
  # a minute; Explore lists the launch within a minute either way.
  @page_reads 30
  @page_read_ms 2_000

  @doc "The assigns a launch card starts with."
  def init(socket) do
    socket
    |> OnchainSteps.init(&followed/1)
    |> assign(signer: nil, mismatch: nil, prepared: nil, reviews: %{}, launched: nil, notice: nil)
  end

  @doc """
  Follows the wallet that may act. A review is built for one signer, so an
  unsent review is dropped when another wallet on the account becomes active.
  With no wallet on the account active it stays, and the note beside its
  button names both wallets.
  """
  def followed(socket) do
    %{linked: linked, active: active, presses: presses, review: review} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    socket = assign(socket, signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))

    cond do
      is_nil(review) or is_nil(signer) -> socket
      review.signer == signer -> socket
      started?(presses, review) -> socket
      true -> withdrawn(socket)
    end
  end

  @doc "Privy's active wallet as the page reported it."
  def activated(socket, params) do
    active = OnchainSteps.active_wallet(params)

    if active == socket.assigns.active,
      do: socket,
      else: socket |> assign(active: active, press_note: nil) |> followed()
  end

  @doc """
  "Review launch": `prepare` is called with the wallet that may act and answers
  `{:ok, prepared}` or `{:error, message}`. With no such wallet nothing is
  prepared: signed out the card says so, with no active wallet Privy's connect
  step opens, and with another wallet open the note beside the button names both.
  """
  def review(socket, prepare) do
    %{linked: linked, active: active, signer: signer} = socket.assigns

    cond do
      is_nil(linked) ->
        assign(socket, notice: "Sign in to launch from your wallet.")

      is_nil(active) ->
        socket |> assign(notice: nil) |> OnchainSteps.connect()

      is_nil(signer) ->
        assign(socket,
          notice: "Switch to a wallet on your account in your wallet app, then press again."
        )

      true ->
        case prepare.(signer) do
          {:ok, prepared} -> reviewed(socket, prepared)
          {:error, message} -> assign(socket, notice: message)
        end
    end
  end

  @doc """
  An agent's press of the card's launch button (`autolaunch_launch`): the step
  the card's own wallet button sends, from the review on the page; with no
  review yet, the review "Review launch" would open, then its step. Answers
  `{reply, socket}`; a reply without a step says why in the card's own words.
  """
  def agent_press(%{assigns: %{review: %{} = review}} = socket, _prepare) do
    case SwapForm.pressable(nil, steps(socket.assigns)) do
      %{name: step} ->
        {sending(review, step), socket}

      nil ->
        {AgentPress.refused(
           "This launch is already created. Its auction page is linked on the page."
         ), socket}
    end
  end

  def agent_press(socket, prepare) do
    socket = review(socket, prepare)

    case socket.assigns do
      %{review: %{steps: [%{step: step} | _rest]} = review} ->
        {sending(review, step), socket}

      %{notice: notice} when is_binary(notice) ->
        {AgentPress.refused(notice), socket}

      _no_wallet ->
        {AgentPress.refused(
           "No wallet is connected in this tab, so the page asked the person to connect one. Call again once they have."
         ), socket}
    end
  end

  defp sending(review, step),
    do:
      review
      |> AgentPress.sending(step, fn _step -> "Create the launch" end)
      |> Map.put(:landed, @launched)

  # The review on the page, and what each review was prepared with, so an
  # outcome is read against the launch it belongs to.
  defp reviewed(socket, prepared) do
    review = Review.new(socket.assigns.id, prepared.signer, prepared.chain, prepared.steps)
    send(self(), {:launch_review, :open})

    socket
    |> assign(
      prepared: prepared,
      notice: nil,
      press_note: nil,
      launched: nil,
      reviews: Map.put(socket.assigns.reviews, review.id, prepared)
    )
    |> OnchainSteps.put_review(review)
    |> OnchainSteps.refresh_later()
  end

  @doc """
  Reads the chain again for the review on the page: `current` answers
  `:current`, `:changed` or `:unread` for what the review was prepared with.
  On `:changed` the review is built again with `prepare`, called with the
  review's signer, and `note` goes beside the new review's button; a review
  that can't be built again stays, with the reason beside its button. While
  its step is on its way the review stays, and a timer asks again later. The
  button is never held for this: it sends whatever review is on the page.
  """
  def rechecked(socket, current, prepare, note \\ nil) do
    %{review: review, presses: presses, prepared: prepared} = socket.assigns

    cond do
      OnchainSteps.pending?(presses, review) ->
        OnchainSteps.refresh_later(socket)

      current.(prepared) == :changed ->
        case prepare.(review.signer) do
          {:ok, prepared} ->
            socket |> reviewed(prepared) |> assign(press_note: note)

          {:error, message} ->
            socket |> assign(press_note: message) |> OnchainSteps.refresh_later()
        end

      true ->
        OnchainSteps.refresh_later(socket)
    end
  end

  @doc """
  The card's `update(%{refresh_review: review_id}, socket)` and revert
  callback: `rechecked/4` when `review_id` is the review on the page.
  """
  def refreshed(%{assigns: %{review: %{id: id}}} = socket, id, current, prepare),
    do: rechecked(socket, current, prepare)

  def refreshed(socket, _earlier_review, _current, _prepare), do: socket

  @doc "A launch step that reverted: the review on the page is checked again."
  def reverted(%{assigns: %{review: %{id: id}}} = socket, %{review: %{id: id}}, current, prepare),
    do: rechecked(socket, current, prepare, @rebuilt)

  def reverted(socket, _earlier_review, _current, _prepare), do: socket

  @doc """
  Takes the review off the page. The page's details forms, locked while a
  review is open (`{:launch_review, :open}`), open again
  (`{:launch_review, :closed}`).
  """
  def withdrawn(socket), do: off_page(socket, :closed)

  # `{:launch_review, :launched}` also tells the page to keep the card while
  # it says the launch is made, though the draft below it is now blank.
  defp off_page(socket, news) do
    send(self(), {:launch_review, news})
    socket |> assign(prepared: nil) |> OnchainSteps.put_review(nil)
  end

  @doc "What the review a sent step came from was prepared with."
  def prepared(socket, %{review: %{id: id}}), do: Map.get(socket.assigns.reviews, id)

  @doc """
  A launch step the page saw confirmed. The review comes off the page and the
  account's draft starts over (`Autolaunch.LaunchedDrafts`), so the form below
  opens blank and the same launch can't be sent again by mistake; the card
  says the launch is made, with its transaction. `draft_kind` is `:revstake`
  or `:memestake`. `find` answers in the background, with what the review was
  prepared with and the hash, `{:ok, path}` for the auction page or `:not_yet`;
  the answer arrives as `handle_async({:launch_page, hash}, ...)`, for
  `found/4`.
  """
  def launched(socket, entry, draft_kind, find) do
    case prepared(socket, entry) do
      nil ->
        socket

      prepared ->
        # The listing clears the same draft again, so a draft this cannot
        # clear just now still starts over within a minute.
        LaunchedDrafts.clear(
          draft_kind,
          socket.assigns.current_human_id,
          prepared.facts["name"],
          prepared.facts["symbol"]
        )

        socket
        |> assign(
          launched: %{
            hash: entry.hash,
            symbol: prepared.facts["symbol"],
            prepared: prepared,
            path: nil,
            finding?: true
          }
        )
        |> off_page(:launched)
        |> find_page(find, 0)
    end
  end

  @doc "One answer of `find` for the launch on the card, as `launched/4` describes."
  def found(%{assigns: %{launched: %{hash: hash} = launched}} = socket, hash, answer, find) do
    case answer do
      {:ok, {_reads, {:ok, path}}} ->
        assign(socket, launched: %{launched | path: path, finding?: false})

      {:ok, {reads, :not_yet}} when reads + 1 < @page_reads ->
        find_page(socket, find, reads + 1)

      _no_page ->
        assign(socket, launched: %{launched | finding?: false})
    end
  end

  def found(socket, _earlier_hash, _answer, _find), do: socket

  defp find_page(%{assigns: %{launched: %{hash: hash, prepared: prepared}}} = socket, find, reads) do
    start_async(socket, {:launch_page, hash}, fn ->
      if reads > 0, do: Process.sleep(@page_read_ms)
      {reads, find.(prepared, hash)}
    end)
  end

  @doc """
  `find` for a Base launch sent from a saved review (`kind` as
  `Autolaunch.LaunchReviews` names it): lists it at once rather than when
  discovery next finds it, and answers its auction page.
  """
  def base_page(kind) do
    fn %{action_id: action_id, chain: %{chain_id: chain_id}}, hash ->
      with {:listed, _account_id, result} <- LaunchReviews.confirm(kind, action_id, hash),
           path when is_binary(path) <- auction_path(chain_id, result["auction"]) do
        {:ok, path}
      else
        _not_yet -> :not_yet
      end
    end
  end

  defp auction_path(chain_id, address) do
    case Autolaunch.get_auction_by_chain_address(chain_id, address,
           actor: %Autolaunch.Actors.System{},
           load: [:path_tail]
         ) do
      {:ok, %{} = auction} -> Paths.auction(auction)
      _unlisted -> nil
    end
  end

  @doc "A press that sent nothing, or may have sent something, in words for the person who pressed."
  def failed(socket, params, flow) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        Telemetry.wallet_failed(flow, reason)
        %{linked: linked, active: active, review: review} = socket.assigns
        chain_name = review && review.chain.name
        assign(socket, press_note: OnchainSteps.failure_note(reason, linked, active, chain_name))

      :error ->
        socket
    end
  end

  @doc "The review's steps as the card shows them."
  def steps(%{review: %{} = review, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: "Create the launch", state: state(entry), entry: entry}
    end)
  end

  def steps(_assigns), do: []

  @doc "The digest of the exact bytes the launch step asks the wallet to sign."
  def digest(%{steps: [%{data: data}]}),
    do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "Whether a step of `review` has been sent."
  def started?(presses, review),
    do: Enum.any?(review.steps, &OnchainSteps.entry(presses, review, &1.step))

  attr :facts, :map, required: true

  @doc """
  What the token itself will say, as the review on the page was built: its
  description, its website and its picture. A launch without a website of the
  creator's own names this site, which is not shown as a website.
  """
  def token_rows(assigns) do
    assigns = assign(assigns, website: MarketCard.web_link(assigns.facts["website"]))

    ~H"""
    <div>
      <dt>Description</dt>
      <dd class="launch-wallet-text">{@facts["description"]}</dd>
    </div>
    <div>
      <dt>Website</dt>
      <dd :if={@website}>{@website.label}</dd>
      <dd :if={!@website}>None given</dd>
    </div>
    <div>
      <dt>Picture</dt>
      <dd><img class="launch-wallet-picture" src={@facts["image"]} alt="" /></dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :steps, :list, required: true
  attr :review, :map, default: nil
  attr :chain, :atom, default: nil, doc: "the explorer's chain; nil on a test network"
  attr :mismatch, :string, default: nil
  attr :press_note, :string, default: nil
  attr :target, :any, required: true

  @doc """
  The review's progress, with each sent step's transaction on the explorer and
  a button to copy its hash, the wallet button, and "Cancel" while nothing is
  on its way.
  """
  def progress(assigns) do
    assigns =
      assign(assigns,
        next_step: Enum.find(assigns.steps, &(&1.state in [:ready, :reverted, :other])),
        chain_name: assigns.review && assigns.review.chain.name
      )

    ~H"""
    <%!-- The list styling drops list semantics, so the role is stated. --%>
    <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
      <li :for={step <- @steps} data-step={step.name}>
        <span>{step.label}</span>
        <.step_state state={chip(step)} />
        <span class="launch-wallet-hash" hidden={!step.entry}>
          <%= if step.entry do %>
            <a
              :if={@chain}
              class="launch-wallet-mono"
              href={BidPlaced.transaction_url(@chain, step.entry.hash)}
              target="_blank"
              rel="noopener noreferrer"
              title={step.entry.hash}
            >
              {RegentFormat.short_hash(step.entry.hash)}
            </a>
            <span :if={!@chain} class="launch-wallet-mono">
              {RegentFormat.short_hash(step.entry.hash)}
            </span>
            <Regent.Primitives.copy_button
              id={"#{@id}-#{step.name}-hash"}
              text={step.entry.hash}
              variant="quiet"
              aria-label="Copy the transaction hash"
            >
              Copy
            </Regent.Primitives.copy_button>
          <% end %>
        </span>
      </li>
    </ol>
    <p
      class="launch-wallet-settled"
      role="status"
      aria-live="polite"
      hidden={!progress_copy(@steps, @chain_name)}
    >
      {progress_copy(@steps, @chain_name)}
    </p>
    <p class="launch-wallet-notice" role="status" hidden={!@press_note}>{@press_note}</p>
    <SwapForm.wallet_step
      next_step={@next_step}
      steps={@steps}
      reverted={reverted_copy(@steps)}
      signer={@review && @review.signer}
      chain_name={@chain_name}
      mismatch={@mismatch}
      check_event="check_again"
      target={@target}
    />
    <div class="launch-wallet-controls">
      <Regent.Primitives.button
        type="button"
        phx-click="cancel_review"
        phx-target={@target}
        variant="secondary"
        hidden={!cancellable?(@steps)}
      >
        Cancel
      </Regent.Primitives.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :launched, :map, default: nil
  attr :chain, :atom, default: nil, doc: "the explorer's chain; nil on a test network"
  attr :target, :any, required: true

  @doc """
  What the card says once its launch is confirmed (`launched/4`): the launch,
  its transaction, and its auction page once the site has it. It takes the
  person's focus, so it is in view however far down they pressed.
  """
  def launched_panel(assigns) do
    ~H"""
    <div
      :if={@launched}
      id={@id}
      class="bid-placed launch-placed"
      role="status"
      tabindex="-1"
      phx-mounted={JS.focus()}
    >
      <p class="bid-placed__news">
        Your token <span class="ticker">{@launched.symbol}</span> is launched.
      </p>
      <p :if={!@chain} class="bid-form__note">
        This was on a test network. Test assets have no real value.
      </p>
      <div class="launch-placed__transaction">
        <span class="launch-wallet-mono">{@launched.hash}</span>
        <Regent.Primitives.copy_button
          id={"#{@id}-hash"}
          text={@launched.hash}
          variant="quiet"
          aria-label="Copy the transaction hash"
        >
          Copy
        </Regent.Primitives.copy_button>
        <a
          :if={@chain}
          href={BidPlaced.transaction_url(@chain, @launched.hash)}
          target="_blank"
          rel="noopener noreferrer"
        >
          View on {BidPlaced.explorer(@chain)} ↗
        </a>
      </div>
      <p>{explore_copy(@launched)}</p>
      <div class="bid-placed__actions">
        <.link
          :if={@launched.path}
          navigate={@launched.path}
          class="rg-button rg-button--primary"
        >
          <span class="rg-button__label">Open the auction</span>
        </.link>
        <Regent.Primitives.button
          type="button"
          phx-click="clear_launch"
          phx-target={@target}
          variant="secondary"
        >
          Launch another
        </Regent.Primitives.button>
      </div>
    </div>
    """
  end

  defp explore_copy(%{path: path}) when is_binary(path), do: "It's on Explore now."
  defp explore_copy(%{finding?: true}), do: "Adding it to Explore…"
  defp explore_copy(_launched), do: "It appears on Explore within a minute."

  defp state(nil), do: :ready

  defp state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp state(%{outcome: :confirmed}), do: :done
  defp state(%{outcome: :reverted}), do: :reverted
  defp state(_not_this_step), do: :other

  defp chip(%{state: :ready}), do: "Ready"
  defp chip(%{state: state}) when state in [:sent, :stalled], do: "Sent"
  defp chip(%{state: :done}), do: "Confirmed"
  defp chip(%{state: :reverted}), do: "Reverted"
  defp chip(%{state: :other}), do: "Unresolved"

  defp cancellable?([]), do: false
  defp cancellable?(steps), do: not Enum.any?(steps, &(&1.state in [:sent, :stalled, :done]))

  defp progress_copy(steps, chain_name) do
    case Enum.find(steps, &(&1.state in [:sent, :stalled, :other])) do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "#{chain_name} has not confirmed this yet. Check again, or look in your wallet activity."

      %{state: :sent} ->
        "Creating the launch…"

      nil ->
        nil
    end
  end

  defp reverted_copy(steps) do
    if Enum.any?(steps, &(&1.state == :reverted)), do: @reverted
  end
end
