defmodule Tank.Ipam do
  @moduledoc """
  Tank's seam to the embedded [Starfish](https://github.com/oshlabs/starfish)
  IPAM: pod NICs declare *intent* (`ip: {:ipam, subnet}`) and the concrete
  address is allocated from the named pool at bring-up — a **static**
  allocation (no lease expiry) with the pod name as its DNS hostname, held
  until the pod is no longer desired.

  ## Wiring

  Enabled by configuring pools; without `:ipam` config nothing starts and
  `{:ipam, _}` NICs fail bring-up with `{:ipam_not_running, nic}`:

      config :tank,
        ipam: [
          prefixes: [%{subnet: "10.0.0.0/24", gateway: "10.0.0.1", dns: ["10.0.0.1"]}],
          reservations: []
        ]

  `child_specs/2` returns the two children `Tank.Application` inserts between
  the store and the reconciler: the Starfish Khepri adapter **attached** to
  Tank's own store (never a second Khepri instance — Starfish data lives under
  a raw `[:starfish]` subtree next to Tank's `[:tank, …]`), and the IPAM
  server under its default name. Starfish's own application supervisor must
  stay disabled (`config :starfish, start?: false`, set by Tank's config).

  ## Semantics

    * **Client identity** is `{:tank_pod, pod_name, nic_name}` — opaque to
      Starfish, stable across restarts, so lease affinity hands a restarting
      pod its previous address even before it re-allocates.
    * **Allocations are observed state**, reconciled level-triggered:
      `reconcile/1` releases any allocation whose pod has left desired state
      (the reconciler calls it every pass), so releases survive crashes and
      missed teardowns.
    * The NIC's `gateway` defaults from the pool's `gateway` when the spec
      leaves it nil — define the network once, in the prefix.
  """

  require Logger

  alias Starfish.IP
  alias Starfish.IP.Subnet
  alias Starfish.IPAM
  alias Starfish.IPAM.Allocation
  alias Tank.{Nic, Pod}
  alias Tank.Pod.Network

  @doc """
  Child specs for the embedded IPAM stack: the Starfish store adapter attached
  to Tank's Khepri store (id from `store_opts`), and the IPAM server seeded
  with the declared pools. Returns `[]` when `ipam_opts` is nil/empty.
  """
  @spec child_specs(keyword | nil, keyword) :: [Supervisor.child_spec() | {module, term}]
  def child_specs(ipam_opts, store_opts \\ [])
  def child_specs(nil, _store_opts), do: []
  def child_specs([], _store_opts), do: []

  def child_specs(ipam_opts, store_opts) do
    store_id = Keyword.get(store_opts, :store_id, :tank)
    ref = {store_id, [:starfish]}

    server_opts =
      [store: {Starfish.Store.Khepri, ref}]
      |> maybe_desired(ipam_opts)

    [
      {Starfish.Store.Khepri, name: store_id},
      {IPAM.Server, server_opts}
    ]
  end

  # Mirror Starfish.Config: only seed desired pools when config declares some,
  # so an empty config never wipes pools already in the durable store.
  defp maybe_desired(opts, ipam_opts) do
    if Keyword.has_key?(ipam_opts, :prefixes) or Keyword.has_key?(ipam_opts, :reservations) do
      desired = %{
        prefixes: Keyword.get(ipam_opts, :prefixes, []),
        reservations: Keyword.get(ipam_opts, :reservations, [])
      }

      Keyword.put(opts, :desired, desired)
    else
      opts
    end
  end

  @doc "Whether the embedded IPAM server is running."
  @spec enabled?() :: boolean
  def enabled?, do: Process.whereis(IPAM.Server) != nil

  @doc """
  Resolves the pod's `{:ipam, subnet}` NIC intents into concrete addresses —
  static allocations keyed on `{:tank_pod, pod, nic}` with the pod name as DNS
  hostname. NICs with explicit addresses pass through untouched; a nil NIC
  `gateway` defaults from the pool's. Called by `Tank.Runtime` at bring-up.
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
      {:ok, resolved} -> {:ok, %Network{network | nics: Enum.reverse(resolved)}}
      {:error, _} = err -> err
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

  @doc """
  Releases every allocation held by pods **not** in `desired_names` — the
  level-triggered garbage collection the reconciler runs each pass. A no-op
  when IPAM isn't running.
  """
  @spec reconcile([String.t()]) :: :ok
  def reconcile(desired_names) do
    if enabled?() do
      desired = MapSet.new(desired_names)

      for %{subnet: subnet} <- IPAM.list_prefixes(),
          %Allocation{status: :active, client: {:tank_pod, pod, _nic}} = alloc <-
            IPAM.list_allocations(subnet),
          not MapSet.member?(desired, pod) do
        Logger.info("Tank.Ipam: releasing #{IP.to_string(alloc.ip)} (pod #{pod} gone)")
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
