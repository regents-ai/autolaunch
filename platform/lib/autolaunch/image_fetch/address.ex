defmodule Autolaunch.ImageFetch.Address do
  @moduledoc false

  @spec public?(:inet.ip_address()) :: boolean()
  def public?({127, _, _, _}), do: false
  def public?({10, _, _, _}), do: false
  def public?({172, second, _, _}) when second in 16..31, do: false
  def public?({192, 168, _, _}), do: false
  def public?({169, 254, _, _}), do: false
  def public?({first, _, _, _}) when first in 224..239, do: false
  def public?({0, 0, 0, 0}), do: false
  def public?({255, 255, 255, 255}), do: false
  def public?({_, _, _, _}), do: true

  def public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def public?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  def public?({hextet, _, _, _, _, _, _, _}) when hextet in 0xFE80..0xFEBF, do: false
  def public?({hextet, _, _, _, _, _, _, _}) when hextet in 0xFC00..0xFDFF, do: false
  def public?({hextet, _, _, _, _, _, _, _}) when hextet in 0xFF00..0xFFFF, do: false

  def public?({0, 0, 0, 0, 0, embed, hi, lo}) when embed in [0, 0xFFFF],
    do: public?(mapped_ipv4(hi, lo))

  def public?({_, _, _, _, _, _, _, _}), do: true
  def public?(_other), do: false

  defp mapped_ipv4(hi, lo) do
    {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
  end
end
