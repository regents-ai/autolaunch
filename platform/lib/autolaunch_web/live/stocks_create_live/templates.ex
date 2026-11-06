defmodule AutolaunchWeb.Live.StocksCreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.CreateNext
  import AutolaunchWeb.Components.CreateForm
  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1]
  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.LaunchKindChoice
  import AutolaunchWeb.Components.StockSelect

  alias Autolaunch.LaunchChain
  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.{Assets, LaunchActions, LaunchDraft, PriceFeeds}
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{DraftMarks, UsdValue}
  alias Phoenix.LiveView.JS

  @link_params ~w(telegram discord other_link_1 other_link_2 other_link_3)

  @sections %{
    "autosave_stocks_token_details" => ~w(name symbol description website) ++ @link_params,
    "autosave_stocks_terms" => ~w(stock_address)
  }

  @stored_params ~w(name symbol description website) ++ @link_params ++ ~w(image stock_address)

  def section_params(event), do: Map.fetch!(@sections, event)
  def draft_field_params, do: @stored_params

  def blank_draft_fields, do: Map.new(@stored_params, &{&1, ""})

  def draft_values(draft),
    do: Map.new(@stored_params, &{&1, Map.get(draft, String.to_existing_atom(&1)) || ""})

  attr :draft, :map, default: nil
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :image_notice, :string, default: nil
  attr :image_color, :string, default: nil
  attr :stocks_image_upload, :map, default: nil
  attr :market, :map, default: %{prices: %{}, venues: []}
  attr :launch_chain, :atom, required: true
  attr :stocks, :any, required: true, doc: "the chain's admitted stocks, or `:unread`"
  attr :stock_sort, :string, required: true
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :account_control, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :status, :atom, default: :ready
  attr :reviewing?, :boolean, default: false
  attr :launched?, :boolean, default: false
  attr :ticker_taken?, :boolean, default: false

  def create(assigns) do
    draft = assigns.draft
    chain = assigns.launch_chain
    stock = stock_for(assigns.stocks, assigns.draft_values["stock_address"])

    assigns =
      assigns
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:missing, LaunchDraft.missing(draft || %{}))
      |> assign(:detail_errors, DraftMarks.marked(assigns.draft_errors, assigns.draft_values))
      |> assign(:links_given?, Enum.any?(@link_params, &(assigns.draft_values[&1] != "")))
      |> assign(:robinhood_open?, Autolaunch.Robinhood.Lab.configured?())
      |> assign(:stock, stock)
      |> assign(:opening, opening(stock, assigns.market.prices))
      |> assign(:fixed_terms, fixed_terms(chain, ticker(assigns.draft_values["symbol"])))

    ~H"""
    <div class="create-page">
      <header class="create-page__header">
        <h1>Create Memestock</h1>
        <.launch_kind_choice current={:memestock} />
      </header>
      <div :if={@status == :error} class="autolaunch-empty" role="alert">
        <h2>Your draft didn’t open</h2>
        <p>It could not be read just now. Nothing you saved is lost.</p>
        <a href="/create" class="rg-button rg-button--primary">
          <span class="rg-button__label">Try again</span>
        </a>
      </div>

      <div :if={@status != :error} class="create-page__layout">
        <section
          id="memestock-form"
          class="create-page__form memestock rg-panel rg-panel--surface"
          data-chain={@launch_chain}
          aria-label="Your memestock"
        >
          <AutolaunchWeb.Components.AgentSetFields.agent_set_fields :if={@draft} draft={@draft} />
          <fieldset class="create-page__lock" disabled={@reviewing?}>
            <form
              id="stocks-token-details"
              class="create-page__fields"
              phx-change="autosave_stocks_token_details"
              phx-submit="autosave_stocks_token_details"
            >
              <div class="create-page__identity">
                <.image_upload
                  upload={@stocks_image_upload}
                  image={@draft_values["image"]}
                  notice={@image_notice}
                />
                <div class="create-page__stack">
                  <.draft_field
                    form_id="stocks-token-details"
                    param="name"
                    label="Name"
                    values={@draft_values}
                    errors={@detail_errors}
                  />
                  <.draft_field
                    form_id="stocks-token-details"
                    param="symbol"
                    label="Ticker"
                    hint={@ticker_taken? && "Another launch already uses this ticker."}
                    values={@draft_values}
                    errors={@detail_errors}
                  />
                  <.menu id="stocks-chain" label="Chain">
                    <:current>
                      <span class={"create-chain create-chain--#{@launch_chain}"} aria-hidden="true"></span>
                      <span class="create-menu__value">{LaunchChain.label(@launch_chain)}</span>
                    </:current>
                    <button
                      :for={chain <- LaunchChain.chains()}
                      type="button"
                      class="create-menu__option"
                      aria-pressed={to_string(@launch_chain == chain)}
                      phx-click={
                        JS.push("choose_chain", value: %{chain: chain})
                        |> close_menu("stocks-chain")
                        |> JS.transition("memestock__form--to-#{chain}",
                          to: "#memestock-form",
                          time: 700
                        )
                      }
                    >
                      <span class={"create-chain create-chain--#{chain}"} aria-hidden="true"></span>
                      <span class="create-menu__name">{LaunchChain.label(chain)}</span>
                      <Regent.Icons.icon name="check" class="create-menu__check" />
                    </button>
                  </.menu>
                </div>
              </div>
              <div class="memestock__paired">
                <span class="create-page__label">Paired stock</span>
                <.stock_select
                  id="stocks-terms-stock_address"
                  name="stock_draft[stock_address]"
                  value={@draft_values["stock_address"]}
                  stocks={@stocks}
                  sort={@stock_sort}
                  sort_event="sort_stocks"
                  retry_event="read_stocks"
                  form="stocks-terms"
                />
                <p :if={@draft_errors["stock_address"]} class="autolaunch-draft-error" role="alert">
                  {@draft_errors["stock_address"]}
                </p>
                <p class="create-page__hint">
                  <.link navigate="/stock-listing" class="standalone-link">Onchain Stocks</.link>
                </p>
                <p
                  :if={@stock && @market.venues != []}
                  id="stocks-terms-buy-at"
                  class="create-page__hint"
                >
                  Buy {@stock.symbol} at
                  <span :for={{venue, index} <- Enum.with_index(@market.venues)}>
                    <span :if={index > 0}>or</span>
                    <a href={venue.url} target="_blank" rel="noopener noreferrer">{venue.name}</a>
                    ({UsdValue.dollars(venue.liquidity_usd)} liquidity)
                  </span>
                </p>
                <p
                  :if={!(@stock && @market.venues != [])}
                  class="create-page__hint create-page__held"
                  aria-hidden="true"
                  inert
                >
                  Buy the stock at a market
                </p>
              </div>
              <div class="create-page__folds">
                <.fold id="stocks-token-about" icon="file-text" title="Description & website" open>
                  <.draft_field
                    form_id="stocks-token-details"
                    param="description"
                    label="Description"
                    kind={:long_text}
                    placeholder="What is this token about?"
                    values={@draft_values}
                    errors={@detail_errors}
                  />
                  <.draft_field
                    form_id="stocks-token-details"
                    param="website"
                    label="Website"
                    optional
                    placeholder="https://"
                    values={@draft_values}
                    errors={@detail_errors}
                  />
                </.fold>
                <.fold id="stocks-token-links" icon="link" title="Links" open={@links_given?}>
                  <div class="create-page__pair">
                    <.draft_field
                      form_id="stocks-token-details"
                      param="telegram"
                      label="Telegram"
                      optional
                      placeholder="https://t.me/yourgroup"
                      values={@draft_values}
                      errors={@detail_errors}
                    />
                    <.draft_field
                      form_id="stocks-token-details"
                      param="discord"
                      label="Discord"
                      optional
                      placeholder="https://discord.gg/invite"
                      values={@draft_values}
                      errors={@detail_errors}
                    />
                  </div>
                  <.draft_field
                    :for={param <- ~w(other_link_1 other_link_2 other_link_3)}
                    form_id="stocks-token-details"
                    param={param}
                    label="Other link"
                    optional
                    placeholder="https://"
                    values={@draft_values}
                    errors={@detail_errors}
                  />
                </.fold>
              </div>
            </form>

            <.fold id="stocks-socials" icon="user" title="Socials">
              <.live_component
                :if={@current_human_id}
                module={AutolaunchWeb.CreatorConnectionsComponent}
                id="creator-connections"
                current_human_id={@current_human_id}
                session_lease={@session_lease}
                bare
                notify
              />
              <.signed_out_socials :if={!@current_human_id} />
            </.fold>

            <%!-- The paired stock sits up with the name, inside the details
                 form, and saves with this one through its fields' form
                 attribute. --%>
            <form
              id="stocks-terms"
              hidden
              phx-change="autosave_stocks_terms"
              phx-submit="autosave_stocks_terms"
            >
            </form>
          </fieldset>
        </section>

        <aside
          id="create-preview"
          class="create-page__side"
          aria-label="Your launch"
        >
          <.summary_card
            id="memestock-summary"
            name={@draft_values["name"]}
            symbol={@draft_values["symbol"]}
            image={@draft_values["image"]}
            color={@image_color}
            pair={if @stock, do: @stock.symbol, else: "stock"}
            chain={@launch_chain}
            sold="49.75%"
            connections={@creator_connections}
            terms={@fixed_terms}
          >
            <:row label="Opening price">
              <MarketCard.price_figure
                :if={@stock}
                amount={@opening.price}
                unit={@stock.symbol}
                rate={@opening.rate}
              />
              <span :if={!@stock}>Choose a stock</span>
            </:row>
            <:row label="FDV">
              {MarketCard.money(@opening.fdv, @opening.rate, @stock && @stock.symbol) ||
                "Choose a stock"}
            </:row>
            <:row label="Paired stock">{if @stock, do: @stock.symbol, else: "Choose one"}</:row>
            <:row label="Creator share">0.5%</:row>
          </.summary_card>

          <div id="stocks-transactions" class="create-page__launch">
            <%!-- One line above the button says why a launch cannot start; the
                 Robinhood line holds its place on Base so switching chains
                 never moves the button. --%>
            <p
              :if={!@robinhood_open? && !(@launch_chain == :base && @launches_paused?)}
              class={@launch_chain != :robinhood && "create-page__held"}
              role={@launch_chain == :robinhood && "status"}
              aria-hidden={@launch_chain != :robinhood && "true"}
              inert={@launch_chain != :robinhood}
            >
              Robinhood launches are not open yet.
              <span :if={@current_human_id}>
                Your draft is saved and will be ready to launch here when they open.
              </span>
            </p>
            <p
              :if={@launch_chain == :base && @launches_paused?}
              class="create-page__notice"
              role="status"
            >
              New launches are paused until the new version opens.
            </p>
            <Regent.Primitives.button
              :if={!@current_human_id}
              type="button"
              class="create-page__launch-button"
              data-account-target="sign-in"
            >
              Sign in to save and launch
            </Regent.Primitives.button>
            <.live_component
              :if={
                @launch_chain == :robinhood && @robinhood_open? &&
                  (@launch_ready? || @reviewing? || @launched?)
              }
              module={AutolaunchWeb.RobinhoodStocksLaunchComponent}
              id={"autolaunch-robinhood-stocks-launch-#{@draft.id}"}
              draft={@draft}
              listings={@listings}
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <.live_component
              :if={@launch_chain == :base && (@launch_ready? || @reviewing? || @launched?)}
              module={AutolaunchWeb.StocksLaunchWalletComponent}
              id={"autolaunch-stocks-launch-wallet-#{@draft.id}"}
              draft={@draft}
              authenticated
              launches_paused?={@launches_paused?}
              listings={@listings}
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <%= if @current_human_id && (@launch_chain == :base || @robinhood_open?) &&
                   !@launch_ready? && !@reviewing? && !@launched? do %>
              <Regent.Primitives.button type="button" class="create-page__launch-button" disabled>
                Review launch
              </Regent.Primitives.button>
              <p class="create-page__need">Still needed: {DraftMarks.still_needed(@missing)}</p>
            <% end %>
            <p
              :if={@draft_notice}
              class={"create-page__notice create-page__notice--#{@draft_notice.tone}"}
              role={if @draft_notice.tone == :error, do: "alert", else: "status"}
            >
              {@draft_notice.message}
            </p>
          </div>

          <.live_component
            :if={
              @current_human_id && @launch_chain == :base &&
                AutolaunchWeb.TestFundsComponent.available?()
            }
            module={AutolaunchWeb.TestFundsComponent}
            id="autolaunch-test-funds"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />
        </aside>
      </div>

      <section
        :if={@status != :error}
        class="create-page__info"
        aria-labelledby="create-info-title"
      >
        <h2 id="create-info-title" class="create-page__info-title">
          Details
        </h2>
        <.launch_plan
          id="memestock-plan"
          kind={:memestock}
          chain={@launch_chain}
          ticker={ticker(@draft_values["symbol"])}
          currency={@stock && @stock.symbol}
          minimum={minimum_raise(@stock)}
          chosen={[
            {"Chain", LaunchChain.label(@launch_chain)},
            {"Paired stock", if(@stock, do: @stock.symbol, else: "Choose a stock")}
          ]}
        />
      </section>
      <.draft_carry_over
        id="memestock-carry-over"
        key="autolaunch:create:memestock"
        signed_in={@current_human_id != nil}
      />
    </div>
    """
  end

  attr :form_id, :string, required: true
  attr :param, :string, required: true
  attr :label, :string, required: true
  attr :kind, :atom, default: :text
  attr :optional, :boolean, default: false
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil
  attr :values, :map, required: true
  attr :errors, :map, required: true

  defp draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.param}"
    error = assigns.errors[assigns.param]

    described_by =
      [assigns.hint && "#{id}-hint", error && "#{id}-error"]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    assigns =
      assign(assigns,
        id: id,
        error: error,
        value: assigns.values[assigns.param],
        described_by: if(described_by == "", do: nil, else: described_by)
      )

    ~H"""
    <div class="rg-field create-field">
      <label for={@id}>
        {@label} <span :if={@optional} class="create-field__optional">optional</span>
      </label>
      <textarea
        :if={@kind == :long_text}
        id={@id}
        name={"stock_draft[#{@param}]"}
        form={@form_id}
        rows="3"
        placeholder={@placeholder}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      >{@value}</textarea>
      <input
        :if={@kind == :text}
        type="text"
        id={@id}
        name={"stock_draft[#{@param}]"}
        form={@form_id}
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      />
      <p :if={@hint} id={"#{@id}-hint"} class="create-page__hint">{@hint}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">{@error}</p>
    </div>
    """
  end

  # The chosen stock as the chain's launchpad admits it, with its decimals.
  defp stock_for(:unread, _address), do: nil
  defp stock_for(_stocks, address) when address in [nil, ""], do: nil

  defp stock_for(stocks, address) do
    case Assets.named(stocks, address) do
      {:ok, stock} -> stock
      :error -> nil
    end
  end

  # What the gallery card shows of a launch no one has bid on yet: its price
  # and FDV at the auction's floor, in the stock, and the stock's dollar price
  # once its feed has answered.
  defp opening(nil, _prices), do: %{price: nil, fdv: nil, rate: nil}

  defp opening(stock, prices),
    do:
      Map.put(
        LaunchActions.opening(stock.decimals),
        :rate,
        prices[PriceFeeds.ticker(stock.symbol)]
      )

  # The whole sale at the starting price, in the chosen stock.
  defp minimum_raise(nil), do: "Choose a stock"

  defp minimum_raise(stock) do
    "#{RegentFormat.token_amount(LaunchActions.minimum_raise(), stock.decimals)} #{stock.symbol}"
  end

  defp fixed_terms(:base, ticker), do: LaunchActions.terms(ticker)
  defp fixed_terms(:robinhood, ticker), do: RobinhoodLaunchActions.terms(ticker)

  # Until the creator names a symbol, the supply is counted in plain tokens.
  defp ticker(symbol) do
    case String.trim(symbol) do
      "" -> "tokens"
      symbol -> symbol
    end
  end
end
