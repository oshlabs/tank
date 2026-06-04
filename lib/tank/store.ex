defmodule Tank.Store do
  @moduledoc """
  The desired-state store seam: Tank's view of the `[:tank, :pods, …]` subtree
  of a Khepri store.

  ## Bring-your-own-or-default

  Tank is a library, so it never owns a store's cluster lifecycle. Which side
  starts Khepri is chosen by the `:data_dir` option:

    * `:data_dir` set — Tank **boots a default store** at that directory and owns
      it (standalone, dev, tests).
    * `:data_dir` `nil` — the store named by `:store_id` is assumed to be started
      by the consumer; Tank only attaches its projection.

  Either way Tank registers a `khepri_projection` mirroring `[:tank, :pods, **]`
  into the ETS table `#{inspect(:tank_pods)}`, so `list_pods/0` is a fast local
  read (the substrate the reconciler will watch). Single-pod reads go straight
  to Khepri so they are authoritative.

  Pods are stored as `%Tank.Pod{}` structs at `[:tank, :pods, name]`.
  """

  use GenServer
  require Logger

  alias Tank.Pod

  @default_store_id :tank
  @projection :tank_pods
  @pods_root [:tank, :pods]

  # ?KHEPRI_WILDCARD_STAR == #if_name_matches{regex = any}: matches every direct
  # child name under [:tank, :pods].
  @wildcard {:if_name_matches, :any, :undefined}
  @pods_pattern @pods_root ++ [@wildcard]

  @store_key {__MODULE__, :store_id}

  # === lifecycle ============================================================

  @doc "Supervisor child spec for the store seam."
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Start the store seam. See the moduledoc for `:store_id` / `:data_dir`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    store_id = Keyword.get(opts, :store_id, @default_store_id)
    data_dir = Keyword.get(opts, :data_dir)

    with {:ok, ^store_id} <- ensure_store(store_id, data_dir),
         :ok <- ensure_projection(store_id) do
      :persistent_term.put(@store_key, store_id)
      {:ok, %{store_id: store_id, owns_store?: data_dir != nil}}
    else
      {:error, reason} -> {:stop, {:store_init_failed, reason}}
    end
  end

  @impl true
  # When Tank booted the default store, stop it on the way down so a dev/test
  # run leaves no Ra server behind. A BYO store is the consumer's to stop.
  def terminate(_reason, %{owns_store?: true, store_id: store_id}) do
    :persistent_term.erase(@store_key)
    _ = :khepri.stop(store_id)
    :ok
  end

  def terminate(_reason, _state) do
    :persistent_term.erase(@store_key)
    :ok
  end

  defp ensure_store(store_id, nil), do: {:ok, store_id}

  defp ensure_store(store_id, data_dir) do
    case :khepri.start(String.to_charlist(data_dir), store_id) do
      {:ok, ^store_id} = ok -> ok
      {:ok, other} -> {:error, {:unexpected_store_id, other}}
      {:error, _} = err -> err
    end
  end

  defp ensure_projection(store_id) do
    projection = :khepri_projection.new(@projection, &__MODULE__.project/2)

    case :khepri.register_projection(store_id, @pods_pattern, projection) do
      :ok -> :ok
      # Idempotent across restarts: the projection outlives this GenServer.
      {:error, {:khepri, :projection_already_exists, _}} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc false
  # The simple projection function: key the ETS row by the pod name (the path
  # leaf). A named, side-effect-free function so Khepri/Horus can compile it
  # into the store machine.
  def project([_tank, _pods, name], %Pod{} = pod), do: {name, pod}

  # === pod CRUD =============================================================

  @doc "Write (create or overwrite) the desired state of a pod."
  @spec put_pod(Pod.t()) :: :ok | {:error, term()}
  def put_pod(%Pod{name: name} = pod), do: normalize(:khepri.put(store_id(), path(name), pod))

  @doc """
  Write a pod only if it does not already exist (the create-if-absent seed
  path). Returns `{:error, :exists}` if a pod with that name is already stored.
  """
  @spec create_pod(Pod.t()) :: :ok | {:error, :exists | term()}
  def create_pod(%Pod{name: name} = pod) do
    case :khepri.create(store_id(), path(name), pod) do
      :ok -> :ok
      {:error, {:khepri, :mismatching_node, _}} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch a single pod by name (authoritative read straight from Khepri)."
  @spec get_pod(String.t()) :: {:ok, Pod.t()} | {:error, :not_found}
  def get_pod(name) when is_binary(name) do
    case :khepri.get(store_id(), path(name)) do
      {:ok, %Pod{} = pod} -> {:ok, pod}
      _ -> {:error, :not_found}
    end
  end

  @doc "Delete a pod by name. Deleting a missing pod is a no-op `:ok`."
  @spec delete_pod(String.t()) :: :ok | {:error, term()}
  def delete_pod(name) when is_binary(name), do: normalize(:khepri.delete(store_id(), path(name)))

  @doc """
  List all stored pods via the ETS projection — a fast local read. Eventually
  consistent with writes (the reconciler is level-triggered, so that is fine).
  """
  @spec list_pods() :: [Pod.t()]
  def list_pods do
    @projection
    |> :ets.tab2list()
    |> Enum.map(fn {_name, pod} -> pod end)
  end

  # === internals ===========================================================

  defp path(name), do: @pods_root ++ [name]

  defp store_id do
    case :persistent_term.get(@store_key, :undefined) do
      :undefined -> raise "Tank.Store is not started"
      store_id -> store_id
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, _} = err), do: err
end
