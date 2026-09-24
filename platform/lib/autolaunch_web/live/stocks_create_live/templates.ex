defmodule AutolaunchWeb.Live.StocksCreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.StockCurrencySelect

  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.{Amounts, LaunchActions, LaunchDraft}

  @new_decimals 18
  @address_hint "0x followed by exactly 40 hexadecimal characters."

  @token_fields [
    %{param: "name", label: "Name", kind: :text, hint: "Up to 64 bytes."},
    %{param: "symbol", label: "Symbol", kind: :text, hint: "Up to 16 bytes."},
    %{param: "description", label: "Description", kind: :long_text, hint: "Up to 512 bytes."},
    %{param: "website", label: "Website", kind: :text, hint: "A link readers can open."}
  ]

  @sections %{
    "autosave_stocks_token_details" => ~w(name symbol description website),
    "autosave_stocks_terms" => ~w(stock_address required_raise floor_price)
  }

  @stored_params ~w(name symbol description website image stock_address required_raise floor_price)

  def section_params(event), do: Map.fetch!(@sections, event)
  def draft_field_params, do: @stored_params

  def blank_draft_fields, do: Map.new(@stored_params, &{&1, ""})

  def draft_values(nil), do: blank_draft_fields()

  def draft_values(draft),
    do: Map.new(@stored_params, &{&1, Map.get(draft, String.to_existing_atom(&1)) || ""})

  attr :draft, :map, default: nil
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :image_notice, :map, default: nil
  attr :stocks_image_upload, :map, default: nil
  attr :stocks_lab, :map, default: nil
  attr :market, :map, default: %{prices: %{}, venues: []}
  attr :launch_chain, :atom, required: true
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :account_control, :map, required: true
  attr :status, :atom, default: :ready

  def create(assigns) do
    draft = assigns.draft

    assigns =
      assigns
      |> assign(:token_complete?, draft && LaunchDraft.token_details_complete?(draft))
      |> assign(:terms_complete?, draft && LaunchDraft.terms_complete?(draft))
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:missing, LaunchDraft.missing(draft || %{}))
      |> assign(:robinhood_open?, Autolaunch.Robinhood.Lab.configured?())
      |> assign(
        :stock,
        stock_for(assigns.launch_chain, assigns.stocks_lab, assigns.draft_values["stock_address"])
      )
      |> assign(:token_fields, @token_fields)
      |> assign(:address_hint, @address_hint)
      |> assign(
        :fixed_terms,
        fixed_terms(assigns.launch_chain, ticker(assigns.draft_values["symbol"]))
      )
      |> assign(:bidding_opens, bidding_opens(assigns.launch_chain))

    assigns =
      assign(assigns, :floor_echo, floor_echo(assigns.draft_values["floor_price"], assigns.stock))

    ~H"""
    <section id="autolaunch-stocks-create">
      <p :if={@status == :error} class="autolaunch-empty">
        Your draft could not be loaded. Refresh and try again.
      </p>

      <section
        :if={@status != :error}
        class="launchpad-create__workspace"
        aria-labelledby="stocks-draft-title"
      >
        <div class="launchpad-create__form-column">
          <form
            id="stocks-token-details"
            phx-change="autosave_stocks_token_details"
            phx-submit="autosave_stocks_token_details"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Public identity</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label" id="stocks-draft-title">Token details</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@token_complete?)}</span>
            </header>
            <div class="launchpad-form-grid">
              <.draft_field
                :for={field <- @token_fields}
                field={field}
                form_id="stocks-token-details"
                value={@draft_values[field.param]}
                error={@draft_errors[field.param]}
              />
            </div>

            <.image_picker
              id="stocks-image"
              upload={@stocks_image_upload}
              image={@draft_values["image"]}
              notice={@image_notice}
            />
          </form>
          <.link_form id="stocks-image" event="stocks_fetch_image_url" />

          <.live_component
            module={AutolaunchWeb.CreatorConnectionsComponent}
            id="creator-connections"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
            optional
          />

          <form
            id="stocks-terms"
            phx-change="autosave_stocks_terms"
            phx-submit="autosave_stocks_terms"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Currency and terms</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Stock and auction terms</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@terms_complete?)}</span>
            </header>

            <.stock_currency_select
              id="stocks-terms-stock_address"
              name="stock_draft[stock_address]"
              value={@draft_values["stock_address"]}
              chain={@launch_chain}
              prices={@market.prices}
            />
            <p :if={@draft_errors["stock_address"]} class="autolaunch-draft-error" role="alert">
              {@draft_errors["stock_address"]}
            </p>
            <p
              :if={@stock && @market.venues != []}
              id="stocks-terms-buy-at"
              class="autolaunch-draft-note stocks-buy-at"
            >
              Users can buy {@stock.symbol} at
              <span :for={{venue, index} <- Enum.with_index(@market.venues)}>
                <span :if={index > 0}>or</span>
                <a href={venue.url} target="_blank" rel="noopener noreferrer">{venue.name}</a>
                ({compact_usd(venue.liquidity_usd)} liquidity{venue_note(@launch_chain)})
              </span>
              in order to bid on {bid_target(@draft_values["symbol"])}.
            </p>

            <.draft_field
              field={
                %{
                  param: "required_raise",
                  label: "Required raise in #{symbol(@stock)}",
                  kind: :text,
                  hint:
                    "The least the auction must raise. If bids fall short, every bid is refundable."
                }
              }
              form_id="stocks-terms"
              value={@draft_values["required_raise"]}
              error={@draft_errors["required_raise"]}
            />
            <.draft_field
              field={
                %{
                  param: "floor_price",
                  label: "Floor price in #{symbol(@stock)} per token",
                  kind: :text,
                  hint: "The lowest price a bid can name."
                }
              }
              form_id="stocks-terms"
              value={@draft_values["floor_price"]}
              error={@draft_errors["floor_price"]}
            />
            <p id="stocks-terms-bidding-opens" class="autolaunch-draft-note">
              Bidding opens {@bidding_opens} after the launch is created. There is no launch fee.
            </p>
            <Regent.Primitives.disclosure
              id="stocks-terms-more-info"
              summary="More info"
              class="stocks-more-info"
            >
              <p :if={@stock} class="autolaunch-draft-hint">
                {@stock.symbol} uses {@stock.decimals} decimal places on {network_name(@launch_chain)}.
              </p>
              <p class="autolaunch-draft-hint">
                Bids, the required raise and refunds all use the selected stock token.
                These assets are listed for selection, not yet admitted for launch execution.
                Asset transfer policies and execution availability require separate verification.
              </p>
              <p
                :if={@floor_echo}
                id="stocks-terms-floor-echo"
                class="autolaunch-draft-hint"
                data-floor-executable={@floor_echo.executable}
              >
                Executable floor:
                <strong>{Amounts.compact_decimal(@floor_echo.executable)} {symbol(@stock)}</strong>
                per token <span :if={@floor_echo.adjusted?}>(rounded down from what you entered)</span>.
              </p>
              <p
                :if={
                  @floor_echo &&
                    Amounts.compact_decimal(@floor_echo.executable) != @floor_echo.executable
                }
                id="stocks-terms-floor-exact"
                class="autolaunch-draft-hint"
              >
                Every digit of the executable floor:
                <span class="autolaunch-exact-value">{@floor_echo.executable} {symbol(@stock)}</span>
              </p>
              <p
                :if={!@floor_echo && @draft_values["floor_price"] != ""}
                class="autolaunch-draft-hint"
              >
                The exact executable floor is shown at review, from the stock token's recorded decimals.
              </p>
            </Regent.Primitives.disclosure>
          </form>

          <section id="stocks-fixed-terms" class="launchpad-form-section rg-panel rg-panel--surface">
            <header>
              <div>
                <p class="autolaunch-kicker">Fixed terms</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Every Memestake launch uses these</h2>
                </Regent.Structure.section_bar>
              </div>
            </header>
            <table class="stocks-terms-table">
              <tbody>
                <tr :for={{label, value} <- @fixed_terms}>
                  <th scope="row">{label}</th>
                  <td>{value}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section
            id="stocks-transactions"
            class="launchpad-form-section launchpad-transactions rg-panel rg-panel--surface"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Wallet review</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Launch transactions</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{if @launch_ready?, do: "Ready", else: "Details required"}</span>
            </header>
            <p :if={@launch_chain == :base || @robinhood_open?}>
              The review shows the executable floor price, the required raise and the schedule
              before anything is submitted. There is no launch fee: your wallet sends one
              transaction that creates the launch.
            </p>
            <p
              :if={@launch_chain == :robinhood && !@robinhood_open?}
              id="stocks-robinhood-pending"
              role="status"
            >
              The Robinhood launchpad is not live yet. Your draft is saved to your account and
              will be ready to launch here when it opens.
            </p>
            <.live_component
              :if={@launch_chain == :robinhood && @robinhood_open? && @launch_ready? && @draft}
              module={AutolaunchWeb.RobinhoodStocksLaunchComponent}
              id={"autolaunch-robinhood-stocks-launch-#{@draft.id}"}
              draft={@draft}
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <.live_component
              :if={@launch_chain == :base && @launch_ready? && @draft}
              module={AutolaunchWeb.StocksLaunchWalletComponent}
              id={"autolaunch-stocks-launch-wallet-#{@draft.id}"}
              draft={@draft}
              authenticated
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <Regent.Primitives.button
              :if={(@launch_chain == :base || @robinhood_open?) && !@launch_ready?}
              type="button"
              disabled
            >
              Still needed: {missing_label(@missing)}
            </Regent.Primitives.button>
          </section>

          <.live_component
            :if={@launch_chain == :base && AutolaunchWeb.TestFundsComponent.available?()}
            module={AutolaunchWeb.TestFundsComponent}
            id="autolaunch-test-funds"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />

          <p
            :if={@draft_notice}
            class={"autolaunch-draft-notice autolaunch-draft-notice--#{@draft_notice.tone}"}
            role={if @draft_notice.tone == :error, do: "alert", else: "status"}
          >
            {@draft_notice.message}
          </p>
        </div>

        <aside
          class="launchpad-create__preview rg-panel rg-support-panel"
          aria-label="Live launch preview"
        >
          <div>
            <p class="autolaunch-kicker">Live preview</p>
            <Regent.Structure.section_bar>
              <h2 class="rg-section-bar__label">Your auction</h2>
            </Regent.Structure.section_bar>
          </div>
          <.autolaunch_market_card
            kind={:draft}
            record={
              Map.merge(@draft_values, %{
                "required_regent_raised" => blank(@draft_values["required_raise"]),
                "preview_metric_unit" => symbol(@stock),
                "preview_metric_label" => "Required raise"
              })
            }
            preview
          />
          <p>Auctions and launched tokens use this same public identity.</p>

          <div>
            <p class="autolaunch-kicker">Summary</p>
            <Regent.Structure.section_bar>
              <h2 class="rg-section-bar__label">Terms</h2>
            </Regent.Structure.section_bar>
          </div>
          <dl class="launch-wallet-terms">
            <div>
              <dt>Token</dt>
              <dd>{blank(@draft_values["name"])} · {blank(@draft_values["symbol"])}</dd>
            </div>
            <div>
              <dt>Bidders pay with</dt>
              <dd>{if @stock, do: @stock.symbol, else: blank(nil)}</dd>
            </div>
            <div>
              <dt>Required raise</dt>
              <dd>{blank(@draft_values["required_raise"])} {symbol(@stock)}</dd>
            </div>
            <div>
              <dt>Bidding opens</dt>
              <dd>{@bidding_opens} after the launch is created</dd>
            </div>
            <div>
              <dt>Floor price</dt>
              <dd>
                {if @floor_echo, do: @floor_echo.executable, else: blank(@draft_values["floor_price"])} {symbol(
                  @stock
                )}
              </dd>
            </div>
          </dl>
        </aside>
      </section>
    </section>
    """
  end

  attr :field, :map, required: true
  attr :form_id, :string, required: true
  attr :value, :string, default: nil
  attr :error, :string, default: nil

  def draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.field.param}"
    hint = assigns.field[:hint]

    described_by =
      [hint && "#{id}-hint", assigns.error && "#{id}-error"]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> nil
        ids -> Enum.join(ids, " ")
      end

    assigns = assign(assigns, id: id, hint: hint, described_by: described_by)

    ~H"""
    <Regent.Primitives.field
      id={@id}
      label={@field.label}
      class={["autolaunch-draft-field", @field.kind == :long_text && "autolaunch-draft-field--wide"]}
    >
      <textarea
        :if={@field.kind == :long_text}
        id={@id}
        name={"stock_draft[#{@field.param}]"}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      >{@value}</textarea>
      <input
        :if={@field.kind == :text}
        type="text"
        id={@id}
        name={"stock_draft[#{@field.param}]"}
        value={@value}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      />
      <p :if={@hint} id={"#{@id}-hint"} class="autolaunch-draft-hint">{@hint}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">{@error}</p>
    </Regent.Primitives.field>
    """
  end

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
        |> Enum.find(&Autolaunch.Chain.Address.equal?(&1.address, address))

      {:error, _closed} ->
        nil
    end
  end

  defp floor_echo(_value, nil), do: nil

  defp floor_echo(value, stock) do
    case Amounts.cca_price(value, stock.decimals, @new_decimals) do
      {:ok, evidence} ->
        executable = evidence.candidate_price_q96 - rem(evidence.candidate_price_q96, 100)

        if executable >= Integer.pow(2, 32) + 1 do
          %{
            executable: Amounts.format_cca_price(executable, stock.decimals, @new_decimals),
            adjusted?: evidence.adjustment_required or executable != evidence.candidate_price_q96
          }
        end

      {:error, _reason} ->
        nil
    end
  end

  defp venue_note(:base), do: ""
  defp venue_note(:robinhood), do: ", the most traded venue"

  defp bid_target(symbol) when symbol in [nil, ""], do: "your token"
  defp bid_target(symbol), do: symbol

  defp fixed_terms(:base, ticker), do: LaunchActions.terms(ticker)
  defp fixed_terms(:robinhood, ticker), do: RobinhoodLaunchActions.terms(ticker)

  # Until the creator names a symbol, the supply is counted in plain tokens.
  defp ticker(symbol) when is_binary(symbol) do
    case String.trim(symbol) do
      "" -> "tokens"
      symbol -> symbol
    end
  end

  defp ticker(_symbol), do: "tokens"

  defp bidding_opens(:base), do: LaunchActions.schedule_copy(LaunchActions.start_lead_blocks())

  defp bidding_opens(:robinhood),
    do: RobinhoodLaunchActions.schedule_copy(RobinhoodLaunchActions.start_lead_blocks())

  defp network_name(:base),
    do: if(Autolaunch.Lab.test_chain?(), do: "this site's Base fork", else: "Base")

  defp network_name(:robinhood),
    do:
      if(Autolaunch.Robinhood.Lab.test_chain?(),
        do: "this site's Robinhood test network",
        else: "Robinhood Chain"
      )

  defp symbol(nil), do: "the stock token"
  defp symbol(%{symbol: symbol}), do: symbol

  defp blank(value) when value in [nil, ""], do: "—"
  defp blank(value), do: value

  @missing_labels %{
    name: "name",
    symbol: "symbol",
    description: "description",
    website: "website",
    image: "image",
    stock_address: "stock",
    required_raise: "required raise",
    floor_price: "floor price"
  }

  defp missing_label(fields) do
    labels = Enum.map(fields, &Map.fetch!(@missing_labels, &1))

    case Enum.split(labels, -1) do
      {[], [only]} -> only
      {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
    end
  end

  defp stage_status(true), do: "Complete"
  defp stage_status(_incomplete), do: "In progress"
end
