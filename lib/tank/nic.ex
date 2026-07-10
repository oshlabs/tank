defmodule Tank.Nic do
  @moduledoc """
  One network interface inside a pod's network namespace.

    * `mode` — `:macvlan` (v1); `:bridge` / `:ipvlan` are modelled for later.
    * `parent` — the host uplink to attach to, or `:auto` to resolve it via
      `Tank.Host`.
    * `ip` — `{address, prefix}` for a static address, `{:ipam, subnet}` to
      draw one from the named pool of the embedded IPAM at bring-up (see
      `Tank.Ipam`), or `:dhcp` (later).
    * `gateway` — optional default-route next hop for this NIC. With an
      `{:ipam, subnet}` address, nil defaults from the pool's gateway.

  Loopback is always raised by the runtime and is not listed here.
  """

  alias Tank.Validate

  @modes [:macvlan, :bridge, :ipvlan]

  @type ip :: {String.t(), 0..32} | {:ipam, String.t()} | :dhcp
  @type t :: %__MODULE__{
          name: String.t(),
          mode: :macvlan | :bridge | :ipvlan,
          parent: String.t() | :auto,
          ip: ip(),
          gateway: String.t() | nil
        }

  @enforce_keys [:name, :ip]
  defstruct name: nil, mode: :macvlan, parent: :auto, ip: nil, gateway: nil

  @keys [:name, :mode, :parent, :ip, :gateway]

  @doc "Build a validated NIC from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, name} <- Validate.name(attrs[:name]),
         {:ok, mode} <- Validate.one_of(Map.get(attrs, :mode, :macvlan), @modes),
         {:ok, parent} <- parent(Map.get(attrs, :parent, :auto)),
         {:ok, ip} <- ip(attrs[:ip]),
         {:ok, gateway} <- gateway(Map.get(attrs, :gateway)) do
      {:ok, %__MODULE__{name: name, mode: mode, parent: parent, ip: ip, gateway: gateway}}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp parent(:auto), do: {:ok, :auto}
  defp parent(p) when is_binary(p) and p != "", do: {:ok, p}
  defp parent(other), do: {:error, {:invalid_parent, other}}

  defp ip(:dhcp), do: {:ok, :dhcp}

  defp ip({:ipam, subnet}) when is_binary(subnet) do
    case Starfish.IP.Subnet.parse(subnet) do
      {:ok, _} -> {:ok, {:ipam, subnet}}
      {:error, _} -> {:error, {:invalid_ipam_subnet, subnet}}
    end
  end

  defp ip({address, prefix}) when is_integer(prefix) and prefix in 0..32 do
    with {:ok, _} <- Validate.ipv4(address), do: {:ok, {address, prefix}}
  end

  defp ip(other), do: {:error, {:invalid_ip, other}}

  defp gateway(nil), do: {:ok, nil}
  defp gateway(gw), do: Validate.ipv4(gw)
end
