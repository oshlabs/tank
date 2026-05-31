defmodule Tank.Pod do
  @moduledoc """
  A pod's desired state: one or more containers sharing a single network
  namespace, the pod-level network and volumes, and a restart policy. The pod
  `name` is the unique key (the Khepri path leaf under `[:tank, :pods, name]`).

    * `containers` — 1+ `Tank.Container`s, unique by name, sharing the netns.
    * `network` — a `Tank.Pod.Network` (the netns is the pod), or the shortcuts
      `:host` (share the host netns) / `:none` (isolated, loopback only).
    * `volumes` — pod-level `Tank.Volume`s; every container `Tank.Mount` must
      reference one by name.
    * `restart` — `:always` | `:on_failure` | `:never` (the reconciler owns
      backoff).

  `new/1` accepts plain maps/keywords for the nested structs and normalises the
  whole tree, so a hand-authored `runtime.exs` pod spec validates in one call.
  """

  alias Tank.{Container, Validate, Volume}
  alias Tank.Pod.Network

  @restarts [:always, :on_failure, :never]

  @type network :: Network.t() | :host | :none
  @type t :: %__MODULE__{
          name: String.t(),
          containers: [Container.t()],
          network: network(),
          volumes: [Volume.t()],
          restart: :always | :on_failure | :never
        }

  @enforce_keys [:name, :containers]
  defstruct name: nil, containers: [], network: :none, volumes: [], restart: :always

  @keys [:name, :containers, :network, :volumes, :restart]

  @doc "Build a validated pod (and its whole nested tree) from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, name} <- Validate.name(attrs[:name]),
         {:ok, containers} <- containers(Map.get(attrs, :containers, [])),
         {:ok, volumes} <- Validate.build_list(Map.get(attrs, :volumes, []), Volume),
         :ok <- Validate.unique(volumes, & &1.name),
         {:ok, network} <- network(Map.get(attrs, :network, :none)),
         {:ok, restart} <- Validate.one_of(Map.get(attrs, :restart, :always), @restarts),
         :ok <- mounts_resolve(containers, volumes) do
      {:ok,
       %__MODULE__{
         name: name,
         containers: containers,
         network: network,
         volumes: volumes,
         restart: restart
       }}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp containers(list) do
    with {:ok, containers} <- Validate.build_list(list, Container),
         :ok <- non_empty(containers),
         :ok <- Validate.unique(containers, & &1.name) do
      {:ok, containers}
    end
  end

  defp non_empty([]), do: {:error, :no_containers}
  defp non_empty(_containers), do: :ok

  defp network(:host), do: {:ok, :host}
  defp network(:none), do: {:ok, :none}
  defp network(%Network{} = n), do: {:ok, n}
  defp network(attrs) when is_map(attrs) or is_list(attrs), do: Network.new(attrs)
  defp network(other), do: {:error, {:invalid_network, other}}

  # Every container mount must reference a volume defined on the pod.
  defp mounts_resolve(containers, volumes) do
    defined = MapSet.new(volumes, & &1.name)

    missing =
      for c <- containers,
          m <- c.mounts,
          not MapSet.member?(defined, m.volume),
          do: {c.name, m.volume}

    if missing == [], do: :ok, else: {:error, {:unknown_volume_refs, missing}}
  end
end
