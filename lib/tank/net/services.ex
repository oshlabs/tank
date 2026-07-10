defmodule Tank.Net.Services do
  @moduledoc """
  Boot actuator for the host-side network services (see `docs/networking.md`):
  resolve the shim spec auto-with-override, actuate it (`Tank.Net.Shim`),
  publish the DNS address for the resolv.conf chain, and apply the DNS
  listener declaratively through `Starfish.Servers`.

  Started by `Tank.Net.child_specs/2` after the IPAM server and the listener
  subtree. Fail-fast on misconfiguration — same posture as `Tank.Store`.
  Boot config is declarative: the configured listener is (re)applied under the
  stable id `:tank`; runtime edits through `Starfish.Servers` persist until
  the next boot re-applies config.

  ## Auto-with-override

    * shim `name` → `"tank0"`; `parent` → `Tank.Host.uplink()`; `pool` → the
      first IPAM pool; `ip` → a static IPAM allocation as `{:tank_host, :shim}`
      with hostname `"tank"` (so the host itself has a DNS name). An explicit
      `ip:` is requested from the pool instead (still recorded in IPAM).
    * dns `origin` → `"tank.internal"`; `listen` → the shim address;
      `port` → 53; `upstream` → `Tank.Host.dns()` (none → external queries
      are refused); the dynamic zone spans every pool.
    * `shim: false` requires an explicit `dns: [listen: …]`.
  """

  use GenServer
  require Logger

  alias Starfish.IP
  alias Starfish.IPAM
  alias Starfish.Servers
  alias Tank.{Host, Net}
  alias Tank.Net.Shim

  @shim_client {:tank_host, :shim}
  @listener_id :tank

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(net_opts) do
    GenServer.start_link(__MODULE__, net_opts, name: __MODULE__)
  end

  @impl true
  def init(net_opts) do
    dns_opts = Keyword.get(net_opts, :dns, [])

    with {:ok, shim} <- ensure_shim(Keyword.get(net_opts, :shim, [])),
         {:ok, listen} <- listen_ip(dns_opts, shim),
         :ok <- ensure_dns(dns_opts, listen) do
      Net.put_dns_ips([IP.to_string(listen)])
      Logger.info("Tank.Net.Services: DNS on #{IP.to_string(listen)} (shim: #{inspect(shim)})")
      {:ok, %{shim: shim, listen: listen}}
    else
      {:error, reason} -> {:stop, {:net_services_failed, reason}}
    end
  end

  # --- shim ------------------------------------------------------------------

  defp ensure_shim(false), do: {:ok, nil}

  defp ensure_shim(opts) do
    with {:ok, subnet} <- shim_pool(opts),
         {:ok, parent} <- shim_parent(opts),
         {:ok, alloc} <- shim_address(opts, subnet) do
      spec = %{
        name: Keyword.get(opts, :name, "tank0"),
        parent: parent,
        ip: IP.to_string(alloc.ip),
        prefix: alloc.prefix.prefix
      }

      case Shim.ensure(spec) do
        :ok -> {:ok, spec}
        {:error, reason} -> {:error, {:shim_failed, reason}}
      end
    end
  end

  defp shim_pool(opts) do
    case Keyword.get(opts, :pool) || first_pool() do
      nil -> {:error, :no_pool}
      subnet -> {:ok, subnet}
    end
  end

  defp first_pool do
    case IPAM.list_prefixes() do
      [%{subnet: subnet} | _] -> subnet
      [] -> nil
    end
  end

  defp shim_parent(opts) do
    case Keyword.get(opts, :parent, :auto) do
      :auto ->
        case Host.uplink() do
          {:ok, parent} -> {:ok, parent}
          {:error, reason} -> {:error, {:no_uplink, reason}}
        end

      parent when is_binary(parent) ->
        {:ok, parent}
    end
  end

  # The shim's address is a normal static allocation — visible in the IPAM
  # view, and "tank" resolves in the dynamic zone like any pod.
  defp shim_address(opts, subnet) do
    result =
      case Keyword.get(opts, :ip, :auto) do
        :auto -> IPAM.allocate(subnet, @shim_client, source: :static, hostname: "tank")
        ip -> IPAM.request(subnet, @shim_client, ip, source: :static, hostname: "tank")
      end

    case result do
      {:ok, alloc} -> {:ok, alloc}
      {:error, reason} -> {:error, {:shim_address_failed, reason}}
    end
  end

  # --- DNS -------------------------------------------------------------------

  defp listen_ip(dns_opts, shim) do
    case Keyword.get(dns_opts, :listen, :shim) do
      :shim ->
        case shim do
          %{ip: ip} -> IP.parse(ip)
          nil -> {:error, :no_listen_address}
        end

      listen when is_binary(listen) ->
        IP.parse(listen)
    end
  end

  defp ensure_dns(dns_opts, %IP{} = listen) do
    zone = %{
      origin: Keyword.get(dns_opts, :origin, "tank.internal"),
      subnets: Enum.map(IPAM.list_prefixes(), & &1.subnet)
    }

    listener =
      [
        ip: to_bind(listen),
        port: Keyword.get(dns_opts, :port, 53),
        dynamic: [zone],
        zones: Keyword.get(dns_opts, :zones, [])
      ]
      |> put_upstream(dns_opts)

    Servers.put_dns(@listener_id, listener)
  end

  defp put_upstream(listener, dns_opts) do
    case Keyword.get(dns_opts, :upstream) || Host.dns() do
      [] -> listener
      servers -> Keyword.put(listener, :upstream, servers: servers)
    end
  end

  # Starfish's DNS listener binds a raw :inet.ip_address() tuple.
  defp to_bind(%IP{} = ip) do
    {:ok, tuple} = ip |> IP.to_string() |> String.to_charlist() |> :inet.parse_address()
    tuple
  end
end
