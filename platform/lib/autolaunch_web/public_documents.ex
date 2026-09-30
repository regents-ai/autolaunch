defmodule AutolaunchWeb.PublicDocuments do
  @moduledoc """
  The pages Autolaunch publishes to people and to agents at the same address.

  Each document is committed Markdown beside this module: an agent that asks for
  `text/markdown` receives it as written, and the page shows the same words as
  HTML. Only these database-free documents are answered before the router;
  every other address reaches it with its own sessions and policies.
  """

  alias AutolaunchWeb.Paths

  @directory Path.join(__DIR__, "public_documents")
  @names ~w(home docs about contact privacy terms llms)
  for name <- @names, do: @external_resource(Path.join(@directory, name <> ".md"))
  @sources Map.new(@names, &{&1, File.read!(Path.join(@directory, &1 <> ".md"))})
  @paths %{
    "/" => "home",
    "/docs" => "docs",
    "/about" => "about",
    "/contact" => "contact",
    "/privacy" => "privacy",
    "/terms" => "terms"
  }

  @contract_path Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @external_resource @contract_path
  @contract YamlElixir.read_from_file!(@contract_path)

  # Every browser tool the pages register, described once; the browser code
  # imports the same file.
  @tool_manifest_path Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource @tool_manifest_path
  @manifest @tool_manifest_path |> File.read!() |> Jason.decode!()
  @tools Map.fetch!(@manifest, "tools")
  @needs %{
    "none" => "Nothing",
    "session" => "The person's sign-in",
    "wallet_signed" => "The person's sign-in and their wallet's confirmation"
  }
  @tool_table """
  | Tool | Where | Needs | What it does |
  | --- | --- | --- | --- |
  #{Enum.map_join(@tools, "\n", &"| `#{&1["name"]}` | #{if &1["scope"] == "site", do: "Every page", else: &1["scope"]} | #{Map.fetch!(@needs, &1["requires"])} | #{&1["description"]} |")}\
  """

  @description "Autolaunch is for backing long-term agents. Raise early funds through an auction. No early snipers here. If you are in the auction, you are early."

  @site_name "Autolaunch"

  # Where security reports go, as the contact page publishes it.
  @security_contact "mailto:security@regents.sh"

  # The documents and the site's fixed pages change only with a release, so the
  # release time is when each last changed.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  @pages %{
    "/" => {@site_name, @description},
    "/create" =>
      {"Create a Memestake token",
       "Pair a new memecoin with a real stock and open its auction on Autolaunch."},
    "/create/revstake" =>
      {"Create a Revstake token",
       "Tokenize a stablecoin-earning service or agent on Base and open its auction."},
    "/auctions" =>
      {"Auctions", "Every Revstake and Memestake auction on Autolaunch, live and graduated."},
    :auction =>
      {"Auction", "An Autolaunch auction on Base: its price, its bids and its time left."},
    :robinhood_auction =>
      {"Robinhood auction",
       "An Autolaunch auction on Robinhood Chain: its price, its bids and its time left."},
    "/tokens" =>
      {"Tokens", "Every token launched through Autolaunch, on Base and Robinhood Chain."},
    :token => {"Token", "A token launched through Autolaunch on Base, to trade and stake."},
    :robinhood_token =>
      {"Robinhood token",
       "A token launched through Autolaunch on Robinhood Chain, to trade and stake."},
    "/how-it-works" =>
      {"How Autolaunch works",
       "How the auction works, and the supply, trading fees and staking rewards for every Autolaunch token."},
    "/portfolio" => {"Portfolio", "Your Autolaunch bids, tokens and stakes in one place."},
    "/profile" => {"Profile", "The accounts you have connected to Autolaunch."},
    "/settings" => {"Settings", "Your Autolaunch sign-in and account."},
    "/regent" =>
      {"REGENT",
       "$REGENT is the value token for all Regents Labs products. Stake it to earn USDC and REGENT."},
    "/convert" =>
      {"REGENT's share of fees",
       "REGENT's share of trading fees waiting in each graduated Memestake launch."},
    "/docs" =>
      {"Developer guide",
       "Read Autolaunch auctions, tokens, bid estimates and treasury reports over HTTP or WebMCP, without an account or API key."},
    "/about" =>
      {"About",
       "What Autolaunch is for, how Revstake and Memestake launches work, and who runs it."},
    "/contact" =>
      {"Contact",
       "How to reach the people behind Autolaunch about launches, security reports, privacy requests and legal questions."},
    "/privacy" =>
      {"Privacy",
       "What Autolaunch keeps about visitors and people who sign in, what becomes public on the chain, and how to ask for removal."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Autolaunch."},
    "/blog" => {"Blog", "Latest updates from Autolaunch."},
    :missing_post => {"Post not found", "There is no Autolaunch blog post at this address."}
  }

  @doc "The public document at `path` as `%{markdown: text}`, or nil for every other address."
  def document(path) do
    case @paths do
      %{^path => name} -> %{markdown: markdown(name)}
      _other -> nil
    end
  end

  @doc "The agent guide served at `/llms.txt`."
  def agent_guide, do: markdown("llms")

  @doc "The browser tool manifest served at `/capabilities`: every tool the pages register."
  def capabilities, do: @manifest

  @doc "Whether the page at `path` also answers as Markdown."
  def markdown?(path), do: Map.has_key?(@paths, path)

  @doc """
  The `page_title` and `page_description` assigns the root layout reads. Every
  page that renders in the root layout assigns them from here.
  """
  def page(key) do
    {title, description} = Map.fetch!(@pages, key)
    [page_title: title, page_description: description]
  end

  @doc "The page's full browser title, the suffix that adds the site name, and its description."
  def metadata(path, title, description) do
    suffix = if path == "/", do: "", else: " · #{@site_name}"
    %{title: title <> suffix, suffix: suffix, description: description}
  end

  @doc "An address on this site, absolute."
  def url(path), do: AutolaunchWeb.Endpoint.url() <> path

  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br table thead tbody tr th td),
    tag_attributes: %{"a" => ["href"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer"
  ]

  @doc "A document's committed Markdown as sanitized HTML."
  # The HTML is MDEx-sanitized from the committed public Markdown.
  # sobelow_skip ["XSS.Raw"]
  def html(markdown) do
    markdown
    |> MDEx.to_html!(extension: [table: true], sanitize: @sanitize)
    |> Phoenix.HTML.raw()
  end

  @doc "Where an agent that reached a missing or refused address can go instead."
  def recovery_links do
    [
      {"Home", url("/")},
      {"Developer guide", url("/docs")},
      {"OpenAPI description", url("/openapi.json")},
      {"Agent guide", url("/llms.txt")},
      {"Sitemap", url("/sitemap.xml")}
    ]
  end

  @doc "The public API description, with this site's address as its server."
  def openapi do
    @contract
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{
      "url" => url("/docs"),
      "description" =>
        "Developer guide: errors, rate limits, and the versioning and deprecation policy"
    })
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  @doc """
  Every public page with the time it last changed: the fixed pages, then each
  listed auction and token, newest first. A fixed page last changed with the
  release; the auction and token lists also change when a listed record does.
  """
  def sitemap do
    auctions =
      Enum.map(Autolaunch.sitemap_auctions!(actor: nil), &{Paths.auction_url(&1), &1.updated_at})

    tokens =
      Enum.map(
        Autolaunch.sitemap_tokens!(actor: nil),
        &{Paths.token_url(&1.auction), &1.updated_at}
      )

    fixed =
      Enum.map(
        ~w(/ /auctions /tokens /how-it-works /regent /docs /about /contact /privacy /terms /blog),
        fn
          "/auctions" = path -> {url(path), latest(auctions)}
          "/tokens" = path -> {url(path), latest(tokens)}
          path -> {url(path), @released_at}
        end
      )

    entries =
      Enum.map_join(fixed ++ auctions ++ tokens, "\n", fn {location, changed} ->
        "  <url><loc>#{escape(location)}</loc><lastmod>#{DateTime.to_iso8601(changed)}</lastmod></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """
  end

  @doc "The RFC 9116 security contact file; it expires a year after the release."
  def security_txt do
    """
    Contact: #{@security_contact}
    Expires: #{@released_at |> DateTime.shift(year: 1) |> DateTime.to_iso8601()}
    Preferred-Languages: en
    Canonical: #{url("/.well-known/security.txt")}
    Policy: #{url("/contact")}
    """
  end

  @doc "The RFC 9727 API catalog: a linkset naming the API, its description and its documentation."
  def api_catalog do
    %{
      "linkset" => [
        %{
          "anchor" => url("/api/v1"),
          "service-desc" => [%{"href" => url("/openapi.json"), "type" => "application/json"}],
          "service-doc" => [%{"href" => url("/docs"), "type" => "text/html"}]
        }
      ]
    }
  end

  @doc "Who Autolaunch is, for a reader that speaks schema.org."
  def structured_data do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "WebApplication",
          "@id" => url("/#application"),
          "name" => "Autolaunch",
          "url" => url("/"),
          "description" => @description,
          "applicationCategory" => "FinanceApplication",
          "operatingSystem" => "Web",
          "image" => url("/images/og-image.png"),
          "sameAs" => ["https://github.com/regents-ai/autolaunch"],
          "publisher" => %{"@id" => "https://regents.sh/#organization"}
        },
        %{
          "@type" => "WebSite",
          "@id" => url("/#website"),
          "name" => "Autolaunch",
          "url" => url("/"),
          "description" => @description,
          "publisher" => %{"@id" => "https://regents.sh/#organization"}
        },
        %{
          "@type" => "Organization",
          "@id" => "https://regents.sh/#organization",
          "name" => "Regents Labs",
          "legalName" => "Regents Labs, Inc.",
          "url" => "https://regents.sh/",
          "sameAs" => ["https://github.com/regents-ai", "https://x.com/regents_sh"],
          "contactPoint" => [
            %{
              "@type" => "ContactPoint",
              "contactType" => "customer support",
              "email" => "build@regents.sh",
              "url" => url("/contact"),
              "availableLanguage" => "English"
            },
            %{
              "@type" => "ContactPoint",
              "contactType" => "security",
              "email" => "security@regents.sh"
            },
            %{
              "@type" => "ContactPoint",
              "contactType" => "privacy",
              "email" => "privacy@regents.sh"
            }
          ]
        }
      ]
    }
  end

  defp markdown(name) do
    @sources[name]
    |> String.replace("{{tools}}", @tool_table)
    |> String.replace("{{origin}}", url(""))
  end

  # A list page last changed with the release or with its newest listed record.
  defp latest(entries),
    do: Enum.max([@released_at | Enum.map(entries, &elem(&1, 1))], DateTime)

  defp escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
