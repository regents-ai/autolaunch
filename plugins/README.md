# Autolaunch plugins

No plugin is implemented or published yet. This directory exists so the intended home is
discoverable; it contains no code.

Agents integrate with Autolaunch today through two existing surfaces:

- the standalone [CLI](../cli/README.md), which exposes public auction, token and quote
  operations as JSON and signs nothing, and
- the [public API and WebMCP contract](../platform/docs/public-webmcp.md), which the website
  serves and the CLI mirrors.

A future plugin would wrap those surfaces rather than add capabilities beyond them. Nothing
here implies a published package, a registry listing or native WebMCP host certification.
