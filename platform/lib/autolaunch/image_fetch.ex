defmodule Autolaunch.ImageFetch do
  @moduledoc false

  alias Autolaunch.ImageFetch.Address
  alias Autolaunch.LaunchDraft.ImageValidator

  @deadline_ms 10_000
  @max_redirects 3

  @type error ::
          :unsupported_scheme
          | :private_address
          | :too_many_redirects
          | :image_too_large
          | :invalid_image
          | :nxdomain
          | :fetch_failed

  @spec fetch(String.t()) :: {:ok, {binary(), String.t()}} | {:error, error()}
  def fetch(url) when is_binary(url), do: fetch(url, [])

  @spec fetch(String.t(), keyword()) :: {:ok, {binary(), String.t()}} | {:error, error()}
  def fetch(url, req_opts) when is_binary(url) and is_list(req_opts) do
    opts = Keyword.merge(Application.get_env(:autolaunch, __MODULE__, []), req_opts)
    fetch_url(url, opts, now_ms() + @deadline_ms, @max_redirects)
  end

  defp fetch_url(url, req_opts, deadline, redirects_left) do
    with {:ok, uri} <- parse_http_uri(url),
         {:ok, remaining} <- remaining_ms(deadline),
         {:ok, ips} <- resolve_public(uri.host),
         {:ok, response} <- request(uri, hd(ips), remaining, req_opts) do
      handle_response(response, uri, req_opts, deadline, redirects_left)
    end
  end

  defp parse_http_uri(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _other ->
        {:error, :unsupported_scheme}
    end
  end

  defp remaining_ms(deadline) do
    remaining = deadline - now_ms()
    if remaining > 0, do: {:ok, remaining}, else: {:error, :fetch_failed}
  end

  defp resolve_public(host) do
    with {:ok, ips} <- lookup(String.to_charlist(host)) do
      if Enum.all?(ips, &Address.public?/1), do: {:ok, ips}, else: {:error, :private_address}
    end
  end

  defp lookup(host_c) do
    case :inet.parse_address(host_c) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, :einval} -> dns(host_c)
    end
  end

  defp dns(host_c) do
    case addrs(host_c, :inet) ++ addrs(host_c, :inet6) do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end

  defp addrs(host_c, family) do
    case :inet.getaddrs(host_c, family) do
      {:ok, ips} -> ips
      {:error, _reason} -> []
    end
  end

  # Req 0.6.2 has Mint :hostname (SNI) but no :address. The URL host is the
  # checked IP so the socket cannot re-resolve; Host and SNI stay the original.
  defp request(uri, ip, remaining, req_opts) do
    max = ImageValidator.maximum_bytes()

    opts =
      req_opts
      |> Keyword.put(:redirect, false)
      |> Keyword.put(:max_redirects, 0)
      |> Keyword.put(:receive_timeout, remaining)
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:connect_options, hostname: uri.host)
      |> Keyword.put(:headers, [{"host", host_header(uri)}])
      |> Keyword.put(:into, &stream_body(&1, &2, max))

    case Req.get(pin_url(uri, ip), opts) do
      {:ok, response} -> {:ok, response}
      {:error, _reason} -> {:error, :fetch_failed}
    end
  end

  defp stream_body({:data, chunk}, {req, resp}, max) do
    if content_length_over?(resp, max) do
      {:halt, {req, abandon_oversize(resp)}}
    else
      acc = if is_binary(resp.body), do: resp.body, else: <<>>
      next = acc <> chunk

      if byte_size(next) > max do
        {:halt, {req, abandon_oversize(resp)}}
      else
        {:cont, {req, %{resp | body: next}}}
      end
    end
  end

  defp abandon_oversize(resp) do
    resp
    |> Map.put(:body, <<>>)
    |> Req.Response.put_private(:image_too_large, true)
  end

  defp pin_url(uri, ip), do: URI.to_string(%{uri | host: ip_literal(ip)})

  defp ip_literal({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp ip_literal(ipv6), do: ipv6 |> :inet.ntoa() |> List.to_string()

  defp host_header(%URI{host: host, port: port, scheme: "https"}) when port in [443, nil],
    do: host

  defp host_header(%URI{host: host, port: port, scheme: "http"}) when port in [80, nil], do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp handle_response(%Req.Response{} = response, uri, req_opts, deadline, left) do
    if Req.Response.get_private(response, :image_too_large) do
      {:error, :image_too_large}
    else
      dispatch_response(response, uri, req_opts, deadline, left)
    end
  end

  defp dispatch_response(%Req.Response{status: status} = response, uri, req_opts, deadline, left)
       when status in [301, 302, 303, 307, 308] do
    follow_redirect(response, uri, req_opts, deadline, left)
  end

  defp dispatch_response(
         %Req.Response{status: 200, body: body} = response,
         _uri,
         _opts,
         _deadline,
         _left
       )
       when is_binary(body) do
    finish_body(response, body)
  end

  defp dispatch_response(_response, _uri, _req_opts, _deadline, _left),
    do: {:error, :invalid_image}

  defp follow_redirect(_response, _uri, _req_opts, _deadline, 0),
    do: {:error, :too_many_redirects}

  defp follow_redirect(response, uri, req_opts, deadline, left) do
    with {:ok, next} <- redirect_location(response, uri) do
      fetch_url(next, req_opts, deadline, left - 1)
    end
  end

  defp redirect_location(response, uri) do
    case Req.Response.get_header(response, "location") do
      [location | _] -> {:ok, uri |> URI.merge(location) |> URI.to_string()}
      _missing -> {:error, :invalid_image}
    end
  end

  defp finish_body(response, body) do
    max = ImageValidator.maximum_bytes()

    cond do
      content_length_over?(response, max) -> {:error, :image_too_large}
      byte_size(body) > max -> {:error, :image_too_large}
      true -> accept_image(body, response)
    end
  end

  defp accept_image(body, response) do
    declared = type_from_bytes(body) || content_type(response)

    case ImageValidator.validate(body, declared) do
      {:ok, type} -> {:ok, {body, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp type_from_bytes(<<137, "PNG", _::binary>>), do: "image/png"
  defp type_from_bytes(<<255, 216, _::binary>>), do: "image/jpeg"
  defp type_from_bytes(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp type_from_bytes(_bytes), do: nil

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

      _missing ->
        ""
    end
  end

  defp content_length_over?(response, max) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} -> n > max
          _other -> false
        end

      _missing ->
        false
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
