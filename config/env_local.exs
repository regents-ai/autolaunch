defmodule Autolaunch.ConfigEnvLocal do
  @env_local_path Path.expand("../.env.local", __DIR__)

  def fetch(key, default \\ "") do
    System.get_env(key) || Map.get(values(), key, default)
  end

  def values do
    case File.read(@env_local_path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case parse_line(line) do
            {key, value} -> Map.put(acc, key, value)
            nil -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        nil

      true ->
        normalized =
          if String.starts_with?(trimmed, "export ") do
            trimmed |> String.replace_prefix("export ", "") |> String.trim()
          else
            trimmed
          end

        case String.split(normalized, "=", parts: 2) do
          [key, value] ->
            {
              String.trim(key),
              value
              |> String.trim()
              |> String.trim_leading("\"")
              |> String.trim_trailing("\"")
              |> String.trim_leading("'")
              |> String.trim_trailing("'")
            }

          _ ->
            nil
        end
    end
  end
end
