defmodule AutolaunchWeb.Live.StocksCreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1]
  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.StockSelect

  alias Autolaunch.LaunchChain
  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.{Amounts, LaunchActions, LaunchDraft}
  alias Phoenix.LiveView.JS

  @new_decimals 18

  @sections %{
    "autosave_stocks_token_details" => ~w(name symbol description website telegram),
    "autosave_stocks_terms" => ~w(stock_address required_raise floor_price)
  }

  @stored_params ~w(name symbol description website telegram image stock_address required_raise floor_price)

  def section_params(event), do: Map.fetch!(@sections, event)
  def draft_field_params, do: @stored_params

  def blank_draft_fields, do: Map.new(@stored_params, &{&1, ""})

  def draft_values(draft),
    do: Map.new(@stored_params, &{&1, Map.get(draft, String.to_existing_atom(&1)) || ""})

  @doc "The page title, and the way to the Revstake launch in the top corner."
  def header(assigns) do
    ~H"""
    <header class="memestock__header">
      <h1>Launch memestock</h1>
      <.link navigate="/create/revstake" class="memestock__alt">
        Agentic Revenue Launch <span aria-hidden="true">→</span>
      </.link>
    </header>
    """
  end

  attr :draft, :map, default: nil
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :image_notice, :string, default: nil
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
    chain = assigns.launch_chain

    assigns =
      assigns
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:missing, LaunchDraft.missing(draft || %{}))
      |> assign(:detail_errors, detail_errors(assigns.draft_errors, draft))
      |> assign(:robinhood_open?, Autolaunch.Robinhood.Lab.configured?())
      |> assign(
        :stock,
        stock_for(chain, assigns.stocks_lab, assigns.draft_values["stock_address"])
      )
      |> assign(:fixed_terms, fixed_terms(chain, ticker(assigns.draft_values["symbol"])))
      |> assign(:schedule, schedule(chain))

    assigns =
      assign(assigns, :floor_echo, floor_echo(assigns.draft_values["floor_price"], assigns.stock))

    ~H"""
    <main class="memestock">
      <.header />
      <p :if={@status == :error} class="autolaunch-empty">
        Your draft could not be loaded. Refresh and try again.
      </p>

      <div :if={@status != :error} class="memestock__layout">
        <section
          id="memestock-form"
          class="memestock__form rg-panel rg-panel--surface"
          data-chain={@launch_chain}
          aria-label="Your memestock"
        >
          <p :if={@live_memestake?} id="memestock-locked" class="memestock__locked" role="status">
            Only one Memestake auction can be live per account
          </p>
          <fieldset class="memestock__lock" disabled={@live_memestake?}>
            <form
              id="stocks-token-details"
              class="memestock__fields"
              phx-change="autosave_stocks_token_details"
              phx-submit="autosave_stocks_token_details"
            >
              <div class="memestock__pair">
                <.draft_field
                  form_id="stocks-token-details"
                  param="name"
                  label="Name"
                  placeholder="Rocket Dog"
                  values={@draft_values}
                  errors={@detail_errors}
                />
                <.draft_field
                  form_id="stocks-token-details"
                  param="symbol"
                  label="Ticker"
                  placeholder="RDOG"
                  values={@draft_values}
                  errors={@detail_errors}
                />
              </div>
              <.draft_field
                form_id="stocks-token-details"
                param="description"
                label="Description"
                kind={:long_text}
                placeholder="What is this token about?"
                values={@draft_values}
                errors={@detail_errors}
              />
              <.image_upload
                upload={@stocks_image_upload}
                image={@draft_values["image"]}
                notice={@image_notice}
              />
              <div class="memestock__pair">
                <.draft_field
                  form_id="stocks-token-details"
                  param="website"
                  label="Website"
                  optional
                  placeholder="https://"
                  values={@draft_values}
                  errors={@detail_errors}
                />
                <.draft_field
                  form_id="stocks-token-details"
                  param="telegram"
                  label="Telegram"
                  optional
                  placeholder="https://t.me/yourgroup"
                  values={@draft_values}
                  errors={@detail_errors}
                />
              </div>
            </form>

            <.live_component
              :if={@current_human_id}
              module={AutolaunchWeb.CreatorConnectionsComponent}
              id="creator-connections"
              current_human_id={@current_human_id}
              session_lease={@session_lease}
              optional
            />

            <form
              id="stocks-terms"
              class="memestock__fields"
              phx-change="autosave_stocks_terms"
              phx-submit="autosave_stocks_terms"
            >
              <div class="memestock__paired">
                <div class="memestock__paired-head">
                  <span class="memestock__label" id="stocks-terms-stock-label">Paired stock</span>
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
                />
                <p :if={@draft_errors["stock_address"]} class="autolaunch-draft-error" role="alert">
                  {@draft_errors["stock_address"]}
                </p>
                <p class="memestock__hint">{pay_line(@launch_chain, @stock)}</p>
                <p
                  :if={@stock && @market.venues != []}
                  id="stocks-terms-buy-at"
                  class="memestock__hint"
                >
                  Buy {@stock.symbol} at
                  <span :for={{venue, index} <- Enum.with_index(@market.venues)}>
                    <span :if={index > 0}>or</span>
                    <a href={venue.url} target="_blank" rel="noopener noreferrer">{venue.name}</a>
                    ({compact_usd(venue.liquidity_usd)} liquidity)
                  </span>
                </p>
              </div>

              <Regent.Primitives.disclosure
                id="stocks-terms-advanced"
                summary="Advanced"
                class="memestock__more"
                phx-mounted={JS.ignore_attributes(["open"])}
              >
                <.draft_field
                  form_id="stocks-terms"
                  param="required_raise"
                  label={"Required raise in #{symbol(@stock)}"}
                  hint="The least the auction must raise. If bids fall short, every bid is refunded."
                  values={@draft_values}
                  errors={@draft_errors}
                />
                <.draft_field
                  form_id="stocks-terms"
                  param="floor_price"
                  label={"Starting price in #{symbol(@stock)} per token"}
                  hint="The price when bidding opens. Bids push it up from here."
                  values={@draft_values}
                  errors={@draft_errors}
                />
                <p
                  :if={@floor_echo && @floor_echo.adjusted?}
                  id="stocks-terms-floor-echo"
                  class="memestock__hint"
                  data-floor-executable={@floor_echo.executable}
                >
                  The auction starts at {Amounts.compact_decimal(@floor_echo.executable)} {symbol(
                    @stock
                  )} per token, the nearest price it can use below what you entered.
                </p>
              </Regent.Primitives.disclosure>
            </form>

            <div id="stocks-transactions" class="memestock__launch">
              <p :if={@launch_chain == :robinhood && !@robinhood_open?} role="status">
                Robinhood launches are not open yet.
                <span :if={@current_human_id}>
                  Your draft is saved and will be ready to launch here when they open.
                </span>
              </p>
              <Regent.Primitives.button
                :if={!@current_human_id}
                type="button"
                class="memestock__launch-button"
                data-account-target="sign-in"
              >
                Sign in to save and launch
              </Regent.Primitives.button>
              <p :if={!@current_human_id} class="memestock__hint">
                Nothing is saved until you sign in. What you have entered comes with you.
              </p>
              <.live_component
                :if={@launch_chain == :robinhood && @robinhood_open? && @launch_ready?}
                module={AutolaunchWeb.RobinhoodStocksLaunchComponent}
                id={"autolaunch-robinhood-stocks-launch-#{@draft.id}"}
                draft={@draft}
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
              <.live_component
                :if={@launch_chain == :base && @launch_ready?}
                module={AutolaunchWeb.StocksLaunchWalletComponent}
                id={"autolaunch-stocks-launch-wallet-#{@draft.id}"}
                draft={@draft}
                authenticated
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
              <Regent.Primitives.button
                :if={
                  @current_human_id && (@launch_chain == :base || @robinhood_open?) && !@launch_ready?
                }
                type="button"
                class="memestock__launch-button"
                disabled
              >
                Still needed: {missing_label(@missing)}
              </Regent.Primitives.button>
              <p
                :if={@draft_notice}
                class={"memestock__notice memestock__notice--#{@draft_notice.tone}"}
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
          </fieldset>
        </section>

        <aside class="memestock__summary rg-panel rg-panel--surface" aria-label="Your token">
          <p class="autolaunch-kicker">Your token</p>
          <div class="memestock-token">
            <img
              :if={@draft_values["image"] != ""}
              src={@draft_values["image"]}
              alt=""
              class="memestock-token__image"
            />
            <span :if={@draft_values["image"] == ""} class="memestock-token__image" aria-hidden="true"></span>
            <div class="memestock-token__names">
              <strong>{present(@draft_values["name"], "Your token")}</strong>
              <span>${present(@draft_values["symbol"], "TICKER")}</span>
            </div>
          </div>
          <dl class="memestock-terms">
            <div>
              <dt>Chain</dt>
              <dd>{LaunchChain.label(@launch_chain)}</dd>
            </div>
            <div>
              <dt>Paired with</dt>
              <dd :if={@stock} class="memestock-terms__stock">
                <.stock_logo stock={@stock} />{@stock.symbol}
              </dd>
              <dd :if={!@stock}>Choose a stock</dd>
            </div>
            <div>
              <dt>Trading fees</dt>
              <dd>1% to stakers · 1% to Regent</dd>
            </div>
            <div>
              <dt>Bidding opens</dt>
              <dd>{@schedule.opens} after launch</dd>
            </div>
            <div>
              <dt>Auction</dt>
              <dd>{@schedule.length}</dd>
            </div>
            <div>
              <dt>Required raise</dt>
              <dd>{present(@draft_values["required_raise"], "—")} {unit(@stock)}</dd>
            </div>
            <div>
              <dt>Starting price</dt>
              <dd>{present(@draft_values["floor_price"], "—")} {unit(@stock)}</dd>
            </div>
            <div>
              <dt>Liquidity</dt>
              <dd>Locked forever</dd>
            </div>
            <div>
              <dt>Launch fee</dt>
              <dd>None</dd>
            </div>
          </dl>
          <Regent.Primitives.disclosure
            id="stocks-fixed-terms"
            summary="Every term"
            class="memestock__more"
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
        </aside>
      </div>
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
    <div class="rg-field memestock-field">
      <label for={@id}>
        {@label} <span :if={@optional} class="memestock-field__optional">optional</span>
      </label>
      <textarea
        :if={@kind == :long_text}
        id={@id}
        name={"stock_draft[#{@param}]"}
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
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      />
      <p :if={@hint} id={"#{@id}-hint"} class="memestock__hint">{@hint}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">{@error}</p>
    </div>
    """
  end

  # A Telegram link saves as typed; until it is a t.me link, the field says so.
  defp detail_errors(errors, %LaunchDraft{} = draft) do
    if :telegram in LaunchDraft.missing(draft),
      do: Map.put_new(errors, "telegram", "Use a link that starts with https://t.me/"),
      else: errors
  end

  defp detail_errors(errors, nil), do: errors

  defp pay_line(:base, stock),
    do: "Bidders pay in #{symbol(stock)}. Stakers earn #{symbol(stock)} from every trade."

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
        |> Enum.find(&Autolaunch.Chain.Address.equal?(&1.address, address))

      {:error, _closed} ->
        nil
    end
  end

  # The executable floor is the entered price rounded down to the auction's
  # price step, never below the auction's minimum.
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

  defp fixed_terms(:base, ticker), do: LaunchActions.terms(ticker)
  defp fixed_terms(:robinhood, ticker), do: RobinhoodLaunchActions.terms(ticker)

  defp schedule(:base),
    do: %{
      opens: LaunchChain.time_estimate(:base, LaunchActions.start_lead_blocks()),
      length: LaunchChain.time_estimate(:base, LaunchActions.auction_duration_blocks())
    }

  defp schedule(:robinhood),
    do: %{
      opens: LaunchChain.time_estimate(:robinhood, RobinhoodLaunchActions.start_lead_blocks()),
      length:
        LaunchChain.time_estimate(:robinhood, RobinhoodLaunchActions.auction_duration_blocks())
    }

  # Until the creator names a symbol, the supply is counted in plain tokens.
  defp ticker(symbol) do
    case String.trim(symbol) do
      "" -> "tokens"
      symbol -> symbol
    end
  end

  defp symbol(nil), do: "the stock"
  defp symbol(%{symbol: symbol}), do: symbol

  # Amounts in the summary name the stock once one is chosen.
  defp unit(nil), do: ""
  defp unit(%{symbol: symbol}), do: symbol

  defp present("", placeholder), do: placeholder
  defp present(value, _placeholder), do: value

  @missing_labels %{
    name: "name",
    symbol: "ticker",
    description: "description",
    website: "website",
    telegram: "a t.me Telegram link",
    image: "image",
    stock_address: "paired stock",
    required_raise: "required raise",
    floor_price: "starting price"
  }

  defp missing_label(fields) do
    labels = Enum.map(fields, &Map.fetch!(@missing_labels, &1))

    case Enum.split(labels, -1) do
      {[], [only]} -> only
      {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
    end
  end
end
