defmodule Tank.Container do
  @moduledoc """
  One container's full lifecycle as a single supervised unit: a workload in its
  own network namespace, configured at the checkpoint, restarted as a whole on
  failure.

  This is the cross-subsystem composite — `Linx.Process` + `Linx.Netlink.Rtnl`
  bound by one lifetime — that the reconcile design says can only live in a
  consumer. `Tank.Container` *is* that consumer.

  ## Spec

      %{
        argv: ["/bin/sleep", "60"],         # required
        namespaces: [:net],                 # required, must include :net
        network: %{
          up: ["lo"],                        # interfaces to bring up
          addresses: [{"lo", "10.0.0.1", 32}],
          routes: []
        },
        owner: self(),                       # optional — receives {:tank, _}
        id: :my_container                    # optional — child_spec id
      }

  ## Lifecycle

  `start_link/1` spawns the workload into a fresh netns (parked at `:ready`),
  configures the namespace from the host (`Rtnl.open({:pid, host_pid})` →
  bring `:up` interfaces up → `Rtnl.Reconcile.reconcile/2` for addresses and
  routes), then `proceed/1`s. The owner receives:

    * `{:tank, :running, host_pid}` — configured and running.
    * `{:tank, :exited, code}` / `{:tank, :signaled, signum}` /
      `{:tank, :error, reason}` — terminal.

  The container GenServer **stops when its workload terminates**, with a reason
  derived from the outcome (clean exit → `:normal`; otherwise abnormal), so a
  supervisor restarts the composite — a brand-new namespace, reconfigured from
  scratch. On stop it reaps the workload via the session's graceful teardown.

  ## Supervision

      children = [
        {Tank.Container,
         %{argv: ["/usr/bin/myd"], namespaces: [:net],
           network: %{up: ["lo"], addresses: [{"lo", "10.0.0.1", 32}]},
           owner: MyApp.Events}}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer
  require Logger

  alias Linx.Process, as: Workload
  alias Linx.Netlink.{Rtnl, Socket}
  alias Linx.Netlink.Rtnl.{Link, Reconcile}

  @type spec :: %{
          required(:argv) => [String.t()],
          required(:namespaces) => [atom()],
          optional(:network) => map(),
          optional(:owner) => pid(),
          optional(:id) => term()
        }

  @doc "Supervisor child spec; restarts the composite on abnormal exit (`:transient`)."
  @spec child_spec(spec()) :: Supervisor.child_spec()
  def child_spec(spec) do
    %{
      id: Map.get(spec, :id, __MODULE__),
      start: {__MODULE__, :start_link, [spec]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Starts and configures one container. See the moduledoc for the spec."
  @spec start_link(spec()) :: GenServer.on_start()
  def start_link(spec) when is_map(spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "The workload's host pid, once `:running`. `{:error, :not_running}` before then."
  @spec host_pid(pid()) :: {:ok, pos_integer()} | {:error, :not_running}
  def host_pid(container), do: GenServer.call(container, :host_pid)

  # === GenServer ============================================================

  @impl true
  def init(spec) do
    cond do
      not is_list(spec[:argv]) or spec[:argv] == [] ->
        {:stop, {:bad_spec, :argv_required}}

      # Configuring the namespace must not touch the host's network: a netns is
      # mandatory so Rtnl.open({:pid, host_pid}) enters the container's own.
      :net not in (spec[:namespaces] || []) ->
        {:stop, {:bad_spec, :net_namespace_required}}

      true ->
        case Workload.spawn(argv: spec.argv, namespaces: spec.namespaces, owner: self()) do
          {:ok, session} ->
            {:ok, %{spec: spec, session: session, host_pid: nil, owner: spec[:owner]}}

          {:error, reason} ->
            {:stop, {:spawn_failed, reason}}
        end
    end
  end

  @impl true
  def handle_call(:host_pid, _from, %{host_pid: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:host_pid, _from, %{host_pid: pid} = state),
    do: {:reply, {:ok, pid}, state}

  @impl true
  # The workload is parked at the checkpoint: its namespace exists but it has
  # not exec'd. Configure the namespace from the host, then let it proceed.
  def handle_info({:linx_process, :ready, host_pid}, state) do
    with :ok <- configure_network(host_pid, Map.get(state.spec, :network, %{})),
         :ok <- Workload.proceed(state.session) do
      {:noreply, %{state | host_pid: host_pid}}
    else
      {:error, reason} ->
        Logger.error("Tank.Container: network configuration failed: #{inspect(reason)}")
        {:stop, {:network_config_failed, reason}, state}
    end
  end

  def handle_info({:linx_process, :running}, state) do
    notify(state, {:tank, :running, state.host_pid})
    {:noreply, state}
  end

  def handle_info({:linx_process, :exited, 0}, state) do
    notify(state, {:tank, :exited, 0})
    {:stop, :normal, state}
  end

  def handle_info({:linx_process, :exited, code}, state) do
    notify(state, {:tank, :exited, code})
    {:stop, {:workload_exited, code}, state}
  end

  def handle_info({:linx_process, :signaled, signum}, state) do
    notify(state, {:tank, :signaled, signum})
    {:stop, {:workload_signaled, signum}, state}
  end

  def handle_info({:linx_process, :error, errno, stage}, state) do
    notify(state, {:tank, :error, {errno, stage}})
    {:stop, {:workload_error, errno, stage}, state}
  end

  # PTY output and any other lifecycle chatter we don't act on.
  def handle_info({:linx_process, _}, state), do: {:noreply, state}
  def handle_info({:linx_process, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  # Reap the workload on the way down so a restart starts from a clean slate.
  # (The session is linked, so it would die with us regardless; stopping it
  # explicitly runs its graceful teardown, which SIGKILLs + reaps the OS child.)
  def terminate(_reason, state) do
    if Process.alive?(state.session), do: GenServer.stop(state.session, :normal)
    :ok
  end

  # === network configuration ================================================

  defp configure_network(host_pid, network) do
    case Rtnl.open({:pid, host_pid}) do
      {:ok, sock} ->
        try do
          do_configure(sock, network)
        after
          Socket.close(sock)
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_configure(sock, network) do
    desired = %{
      addresses: Map.get(network, :addresses, []),
      routes: Map.get(network, :routes, [])
    }

    with :ok <- bring_up(sock, Map.get(network, :up, [])),
         {:ok, report} <- Reconcile.reconcile(sock, desired) do
      if report.converged?, do: :ok, else: {:error, {:not_converged, report}}
    end
  end

  defp bring_up(sock, links) do
    Enum.reduce_while(links, :ok, fn name, :ok ->
      case Link.set_up(sock, name) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp notify(%{owner: nil}, _msg), do: :ok
  defp notify(%{owner: owner}, msg), do: send(owner, msg)
end
