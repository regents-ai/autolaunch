defmodule AutolaunchWeb.Live.StocksCreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.CreateNext
  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1]
  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.LaunchKindChoice
  import AutolaunchWeb.Components.StockSelect

  alias Autolaunch.LaunchChain
  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.{Amounts, LaunchActions, LaunchDraft, PriceFeeds}
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{DraftMarks, TokenDisplay}
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

  @doc "The choice between the two launches, then the page title."
  def header(assigns) do
    ~H"""
    <.launch_kind_choice current={:memestock} />
    <header class="create-page__header">
      <h1>Create a Memestock token</h1>
    </header>
    """
  end

  attr :draft, :map, default: nil
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :image_notice, :string, default: nil
  attr :image_color, :string, default: nil
  attr :stocks_image_upload, :map, default: nil
  attr :stocks_lab, :map, default: nil
  attr :market, :map, default: %{prices: %{}, venues: []}
  attr :launch_chain, :atom, required: true
  attr :stock_sort, :string, required: true
  attr :stock_records, :map, required: true
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
    stock = stock_for(chain, assigns.stocks_lab, assigns.draft_values["stock_address"])

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
    <main class="create-page">
      <.header />
      <p :if={@status == :error} class="autolaunch-empty">
        Your draft could not be loaded. Refresh and try again.
      </p>

      <div :if={@status != :error} class="create-page__layout create-page__layout--preview">
        <section
          id="memestock-form"
          class="create-page__form memestock rg-panel rg-panel--surface"
          data-chain={@launch_chain}
          aria-label="Your memestock"
        >
          <fieldset class="create-page__lock" disabled={@reviewing?}>
            <form
              id="stocks-token-details"
              class="create-page__fields"
              phx-change="autosave_stocks_token_details"
              phx-submit="autosave_stocks_token_details"
            >
              <div class="create-page__pair">
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
              </div>
              <div class="memestock__paired">
                <div class="memestock__paired-head">
                  <span class="create-page__label" id="stocks-terms-stock-label">Paired stock</span>
                  <div class="chain-switch" role="group" aria-label="Chain">
                    <button
                      :for={chain <- LaunchChain.chains()}
                      type="button"
                      class={"chain-switch__option chain-switch__option--#{chain}"}
                      aria-pressed={to_string(@launch_chain == chain)}
                      phx-click={
                        JS.push("choose_chain", value: %{chain: chain})
                        |> JS.transition("memestock__form--to-#{chain}",
                          to: "#memestock-form",
                          time: 700
                        )
                      }
                    >
                      {LaunchChain.label(chain)}
                    </button>
                  </div>
                </div>
                <.stock_select
                  id="stocks-terms-stock_address"
                  name="stock_draft[stock_address]"
                  value={@draft_values["stock_address"]}
                  chain={@launch_chain}
                  sort={@stock_sort}
                  sort_event="sort_stocks"
                  records={@stock_records[@launch_chain]}
                  form="stocks-terms"
                />
                <p :if={@draft_errors["stock_address"]} class="autolaunch-draft-error" role="alert">
                  {@draft_errors["stock_address"]}
                </p>
                <p class="create-page__hint">{pay_line(@launch_chain, @stock)}</p>
                <p
                  :if={@stock && @market.venues != []}
                  id="stocks-terms-buy-at"
                  class="create-page__hint"
                >
                  Buy {@stock.symbol} at
                  <span :for={{venue, index} <- Enum.with_index(@market.venues)}>
                    <span :if={index > 0}>or</span>
                    <a href={venue.url} target="_blank" rel="noopener noreferrer">{venue.name}</a>
                    ({compact_usd(venue.liquidity_usd)} liquidity)
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
              <.image_upload
                upload={@stocks_image_upload}
                image={@draft_values["image"]}
                notice={@image_notice}
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
              <Regent.Primitives.disclosure
                id="stocks-token-links"
                summary="Community Links"
                class="create-page__more create-page__box"
                open={@links_given?}
                phx-mounted={JS.ignore_attributes(["open"])}
              >
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
              </Regent.Primitives.disclosure>
            </form>

            <.live_component
              :if={@current_human_id}
              module={AutolaunchWeb.CreatorConnectionsComponent}
              id="creator-connections"
              current_human_id={@current_human_id}
              session_lease={@session_lease}
              optional
              notify
            />
            <p :if={!@current_human_id} class="create-page__hint">
              After you sign in, you can connect X, GitHub or ENS to show on your auction and token.
            </p>

            <.draft_field
              form_id="stocks-token-details"
              param="description"
              label="Description"
              kind={:long_text}
              placeholder="What is this token about?"
              values={@draft_values}
              errors={@detail_errors}
            />
            <%!-- The paired stock sits up with the name, inside the details
                 form, and saves with this one through its fields' form
                 attribute; the description below saves with the details. --%>
            <form
              id="stocks-terms"
              hidden
              phx-change="autosave_stocks_terms"
              phx-submit="autosave_stocks_terms"
            >
            </form>
          </fieldset>
          <div id="stocks-transactions" class="create-page__launch">
            <p
              :if={!@robinhood_open?}
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
            <Regent.Primitives.button
              :if={!@current_human_id}
              type="button"
              class="create-page__launch-button"
              data-account-target="sign-in"
            >
              Sign in to save and launch
            </Regent.Primitives.button>
            <p :if={!@current_human_id} class="create-page__hint">
              Nothing is saved until you sign in. What you have entered comes with you.
            </p>
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
              listings={@listings}
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <Regent.Primitives.button
              :if={
                @current_human_id && (@launch_chain == :base || @robinhood_open?) && !@launch_ready? &&
                  !@reviewing? && !@launched?
              }
              type="button"
              class="create-page__launch-button"
              disabled
            >
              Still needed: {DraftMarks.still_needed(@missing)}
            </Regent.Primitives.button>
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
        </section>

        <aside
          id="create-preview"
          class="create-page__preview"
          aria-label="Your auction as the gallery will show it"
        >
          <MarketCard.draft_card
            name={@draft_values["name"]}
            symbol={String.upcase(@draft_values["symbol"])}
            image={@draft_values["image"]}
            color={@image_color}
            website={@draft_values["website"]}
            chain={LaunchChain.label(@launch_chain)}
            unit={@stock && @stock.symbol}
            price={@opening.price}
            fdv={@opening.fdv}
            rate={@opening.rate}
            creator_connections={@creator_connections}
          />
        </aside>
      </div>

      <section
        :if={@status != :error}
        class="create-page__info"
        aria-labelledby="create-info-title"
      >
        <h2 id="create-info-title" class="create-page__info-title">
          Auction and Token Information
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
        <div class="create-next__card">
          <Regent.Primitives.disclosure
            id="stocks-fixed-terms"
            summary="Every term"
            class="create-page__more"
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <table class="stocks-terms-table">
              <tbody>
                <tr :for={{label, value} <- @fixed_terms}>
                  <th scope="row">{label}</th>
                  <td>{value}</td>
                </tr>
              </tbody>
            </table>
          </Regent.Primitives.disclosure>
        </div>
      </section>
      <.draft_carry_over
        id="memestock-carry-over"
        key="autolaunch:create:memestock"
        signed_in={@current_human_id != nil}
      />
    </main>
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

  defp pay_line(:base, stock),
    do: "Bidders pay in #{symbol(stock)}. Stakers earn #{symbol(stock)} from every trade."

  defp pay_line(:robinhood, nil),
    do: "Bidders pay in USDG, swapped into the stock. Stakers earn it from every trade."

  defp pay_line(:robinhood, stock),
    do:
      "Bidders pay in USDG, swapped into #{symbol(stock)}. Stakers earn #{symbol(stock)} from every trade."

  # The stock as this site's lab admits it, with its recorded decimals. Without
  # a Stocks lab the decimals are only known at review, from the launchpad.
  defp stock_for(_chain, _config, address) when address in [nil, ""], do: nil
  defp stock_for(:base, nil, _address), do: nil
  defp stock_for(:base, config, address), do: Autolaunch.Stocks.Lab.stock(config, address)

  defp stock_for(:robinhood, _config, address) do
    case Autolaunch.Robinhood.Lab.current() do
      {:ok, config} ->
        config
        |> Autolaunch.Robinhood.Lab.stocks()
        |> Enum.find(&RegentChain.Address.equal?(&1.address, address))

      {:error, _closed} ->
        nil
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
    {:ok, amount} = Amounts.format_units(LaunchActions.minimum_raise(), stock.decimals)
    TokenDisplay.zeros("#{TokenDisplay.short(amount, :down)} #{stock.symbol}")
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

  defp symbol(nil), do: "the stock"
  defp symbol(%{symbol: symbol}), do: symbol
end
