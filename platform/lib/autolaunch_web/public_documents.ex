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
  @names ~w(home developers about contact privacy llms)
  for name <- @names, do: @external_resource(Path.join(@directory, name <> ".md"))
  @sources Map.new(@names, &{&1, File.read!(Path.join(@directory, &1 <> ".md"))})
  @paths %{
    "/" => "home",
    "/developers" => "developers",
    "/about" => "about",
    "/contact" => "contact",
    "/privacy" => "privacy"
  }

  @contract_path Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @external_resource @contract_path
  @contract YamlElixir.read_from_file!(@contract_path)

  # Every browser tool the pages register, described once; the browser code
  # imports the same file.
  @tool_manifest_path Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource @tool_manifest_path
  @tools @tool_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")
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

  @pages %{
    "/developers" =>
      {"Autolaunch developer guide",
       "Read Autolaunch auctions, tokens, bid estimates and treasury reports over HTTP or WebMCP, without an account or API key."},
    "/about" =>
      {"About Autolaunch",
       "What Autolaunch is for, how Revstake and Memestake launches work, and who runs it."},
    "/contact" =>
      {"Contact Autolaunch",
       "How to reach the people behind Autolaunch about launches, security reports, privacy requests and legal questions."},
    "/privacy" =>
      {"Autolaunch privacy",
       "What Autolaunch keeps about visitors and people who sign in, what becomes public on the chain, and how to ask for removal."}
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

  @doc "Whether the page at `path` also answers as Markdown."
  def markdown?(path), do: Map.has_key?(@paths, path)

  @doc "The browser title and search description of a document page."
  def page(path), do: Map.fetch!(@pages, path)

  @doc "The site's description, for pages that do not name their own."
  def description, do: @description

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
      {"Developer guide", url("/developers")},
      {"OpenAPI description", url("/openapi.json")},
      {"Agent guide", url("/llms.txt")},
      {"Sitemap", url("/sitemap.xml")}
    ]
  end

  @doc "The public API description, with this site's address as its server."
  def openapi do
    @contract
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{"url" => url("/developers"), "description" => "Developer guide"})
  end

  @doc """
  Every public page with the time it last changed: the fixed pages, then each
  listed auction and token, newest first. The fixed pages have no recorded
  change time, so they carry none.
  """
  def sitemap do
    fixed =
      Enum.map(
        ~w(/ /auctions /tokens /how-it-works /regent /developers /about /contact /privacy /blog),
        &{url(&1), nil}
      )

    auctions =
      Enum.map(Autolaunch.sitemap_auctions!(actor: nil), &{Paths.auction_url(&1), &1.updated_at})

    tokens =
      Enum.map(
        Autolaunch.sitemap_tokens!(actor: nil),
        &{Paths.token_url(&1.auction), &1.updated_at}
      )

    entries =
      Enum.map_join(fixed ++ auctions ++ tokens, "\n", fn {location, changed} ->
        "  <url><loc>#{escape(location)}</loc>#{lastmod(changed)}</url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """
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

  defp lastmod(nil), do: ""
  defp lastmod(%DateTime{} = at), do: "<lastmod>#{DateTime.to_iso8601(at)}</lastmod>"

  defp escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
