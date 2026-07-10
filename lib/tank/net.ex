defmodule Tank.Net do
  @moduledoc """
  The seam to the embedded [Starfish](https://github.com/oshlabs/starfish)
  network services: IPAM-backed pod addressing and the host DNS service.
  Design record: `docs/networking.md` (config surface, auto-with-override
  chains, networking modes).

  Pod NICs declare *intent* (`ip: {:ipam, subnet}`) and the concrete address
  is allocated from the named pool at bring-up — a **static** allocation (no
  lease expiry) with the pod name as its DNS hostname, held until the pod is
  no longer desired.

  ## Wiring

  Everything under one config key; `pools` is the only part without a
  derivable default:

      config :tank,
        net: [
          pools: [%{subnet: "10.0.0.0/24", gateway: "10.0.0.1"}],
          reservations: [],
          shim: [name: "tank0", parent: :auto, ip: :auto],   # or false
          dns: [origin: "tank.internal", upstream: ["9.9.9.9"]]  # or false
        ]

  `child_specs/2` returns the children `Tank.Application` inserts between the
  store and the reconciler: the Starfish Khepri adapter **attached** to Tank's
  own store (never a second Khepri instance — Starfish data lives under a raw
  `[:starfish]` subtree next to Tank's `[:tank, …]`), the IPAM server, and —
  unless disabled — the listener subtree plus `Tank.Net.Services` (the boot
  actuator: host shim interface + DNS listener). Starfish's own application
  supervisor must stay disabled (`config :starfish, start?: false`, set by
  Tank's config).

  ## Semantics

    * **Client identity** is `{:tank_pod, pod_name, nic_name}` — opaque to
      Starfish, stable across restarts, so lease affinity hands a restarting
      pod its previous address even before it re-allocates. The host shim
      allocates as `{:tank_host, :shim}`.
    * **Allocations are observed state**, reconciled level-triggered:
      `reconcile/1` releases any pod allocation whose pod has left desired
      state (the reconciler calls it every pass), so releases survive crashes
      and missed teardowns.
    * **Auto-with-override**: NIC `gateway` defaults from the pool's;
      the pod's resolv.conf chain is pod `dns` → pool `dns` → the DNS
      service's own address → `Tank.Host.dns()` (the last step in
      `Tank.Runtime.Etc`).
  """

  require Logger

  alias Starfish.IP
  alias Starfish.IP.Subnet
  alias Starfish.IPAM
  alias Starfish.IPAM.Allocation
  alias Tank.{Nic, Pod}
  alias Tank.Pod.Network

  @dns_ips_key {__MODULE__, :dns_ips}

  @doc """
  Child specs for the embedded network-services stack: the Starfish store
  adapter attached to Tank's Khepri store (id from `store_opts`), the IPAM
  server seeded with the declared pools, and — unless `dns: false` — the
  listener subtree + `Tank.Net.Services`. Returns `[]` when `net_opts` is
  nil/empty.
  """
  @spec child_specs(keyword | nil, keyword) :: [Supervisor.child_spec() | {module, term}]
  def child_specs(net_opts, store_opts \\ [])
  def child_specs(nil, _store_opts), do: []
  def child_specs([], _store_opts), do: []

  def child_specs(net_opts, store_opts) do
    store_id = Keyword.get(store_opts, :store_id, :tank)
    ref = {store_id, [:starfish]}

    [
      {Starfish.Store.Khepri, name: store_id},
      {IPAM.Server, ipam_opts(net_opts, ref)}
    ] ++ services_specs(net_opts, ref)
  end

  defp ipam_opts(net_opts, ref) do
    [store: {Starfish.Store.Khepri, ref}] |> maybe_desired(net_opts)
  end

  # Mirror Starfish.Config: only seed desired pools when config declares some,
  # so an empty config never wipes pools already in the durable store.
  defp maybe_desired(opts, net_opts) do
    if Keyword.has_key?(net_opts, :pools) or Keyword.has_key?(net_opts, :reservations) do
      desired = %{
        prefixes: Keyword.get(net_opts, :pools, []),
        reservations: Keyword.get(net_opts, :reservations, [])
      }

      Keyword.put(opts, :desired, desired)
    else
      opts
    end
  end

  # The DNS service defaults ON (auto-with-override): `dns: false` disables it
  # and the shim with it. `shim: false` plus `dns: [listen: …]` runs the
  # listener on an explicit address instead (see Tank.Net.Services).
  defp services_specs(net_opts, ref) do
    if Keyword.get(net_opts, :dns) == false do
      []
    else
      [
        {Starfish.Servers.Supervisor, store: {Starfish.Store.Khepri, ref}, ipam: IPAM.Server},
        {Tank.Net.Services, net_opts}
      ]
    end
  end

  @doc "Whether the embedded IPAM server is running."
  @spec enabled?() :: boolean
  def enabled?, do: Process.whereis(IPAM.Server) != nil

  @doc """
  Resolves the pod's `{:ipam, subnet}` NIC intents into concrete addresses —
  static allocations keyed on `{:tank_pod, pod, nic}` with the pod name as DNS
  hostname. NICs with explicit addresses pass through untouched; a nil NIC
  `gateway` defaults from the pool's, and an empty `network.dns` defaults from
  the pool's `dns` (falling back to the embedded DNS service's own address).
  Called by `Tank.Runtime` at bring-up, before `/etc` materialization.
  """
  @spec resolve(Pod.t()) :: {:ok, Pod.network()} | {:error, term}
  def resolve(%Pod{network: %Network{nics: nics} = network} = pod) do
    nics
    |> Enum.reduce_while({:ok, []}, fn nic, {:ok, acc} ->
      case resolve_nic(pod.name, nic) do
        {:ok, nic} -> {:cont, {:ok, [nic | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, resolved} ->
        {:ok, %Network{network | nics: Enum.reverse(resolved), dns: default_dns(network)}}

      {:error, _} = err ->
        err
    end
  end

  # :host / :none need no resolution.
  def resolve(%Pod{network: network}), do: {:ok, network}

  defp resolve_nic(pod_name, %Nic{ip: {:ipam, subnet}} = nic) do
    if enabled?() do
      client = client(pod_name, nic.name)

      case IPAM.allocate(subnet, client, source: :static, hostname: pod_name) do
        {:ok, %Allocation{ip: ip, prefix: %Subnet{prefix: len}}} ->
          {:ok, %Nic{nic | ip: {IP.to_string(ip), len}, gateway: nic.gateway || gateway(subnet)}}

        {:error, reason} ->
          {:error, {:ipam_allocate_failed, nic.name, reason}}
      end
    else
      {:error, {:ipam_not_running, nic.name}}
    end
  end

  defp resolve_nic(_pod_name, nic), do: {:ok, nic}

  # The resolv.conf chain for pods on an IPAM pool: explicit pod dns wins; then
  # the pool's dns list; then the DNS service's own address (published by
  # Tank.Net.Services). Left empty, Tank.Runtime.Etc falls back to Host.dns().
  defp default_dns(%Network{dns: [_ | _] = dns}), do: dns

  defp default_dns(%Network{nics: nics}) do
    nics
    |> Enum.find_value(fn
      %Nic{ip: {:ipam, subnet}} -> subnet
      _ -> nil
    end)
    |> case do
      nil ->
        []

      subnet ->
        case pool_dns(subnet) do
          [] -> dns_ips()
          dns -> dns
        end
    end
  end

  defp pool_dns(subnet) do
    with {:ok, wanted} <- Subnet.parse(subnet),
         %{dns: [_ | _] = dns} <- Enum.find(IPAM.list_prefixes(), &(&1.subnet == wanted)) do
      Enum.map(dns, &IP.to_string/1)
    else
      _ -> []
    end
  end

  @doc false
  # Published by Tank.Net.Services once the DNS listener is up; read by the
  # resolv.conf chain.
  @spec put_dns_ips([String.t()]) :: :ok
  def put_dns_ips(ips), do: :persistent_term.put(@dns_ips_key, ips)

  @doc "The embedded DNS service's addresses (empty when it isn't running)."
  @spec dns_ips() :: [String.t()]
  def dns_ips, do: :persistent_term.get(@dns_ips_key, [])

  @doc false
  # Test hygiene: clear the published DNS address.
  def clear_dns_ips, do: :persistent_term.erase(@dns_ips_key)

  @doc """
  Releases every pod allocation held by pods **not** in `desired_names` — the
  level-triggered garbage collection the reconciler runs each pass. Host
  allocations (`{:tank_host, _}` — the shim) are never touched. A no-op when
  IPAM isn't running.
  """
  @spec reconcile([String.t()]) :: :ok
  def reconcile(desired_names) do
    if enabled?() do
      desired = MapSet.new(desired_names)

      for %{subnet: subnet} <- IPAM.list_prefixes(),
          %Allocation{status: :active, client: {:tank_pod, pod, _nic}} = alloc <-
            IPAM.list_allocations(subnet),
          not MapSet.member?(desired, pod) do
        Logger.info("Tank.Net: releasing #{IP.to_string(alloc.ip)} (pod #{pod} gone)")
        _ = IPAM.release(alloc.ip)
      end
    end

    :ok
  end

  defp client(pod_name, nic_name), do: {:tank_pod, pod_name, nic_name}

  defp gateway(subnet) do
    with {:ok, wanted} <- Subnet.parse(subnet),
         %{gateway: %IP{} = gw} <- Enum.find(IPAM.list_prefixes(), &(&1.subnet == wanted)) do
      IP.to_string(gw)
    else
      _ -> nil
    end
  end
end
