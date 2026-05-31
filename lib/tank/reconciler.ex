defmodule Tank.Reconciler do
  @moduledoc """
  The level-triggered control loop that converges running pods to the desired
  state in `Tank.Store`. This is what closes the declarative loop: you
  `Tank.apply/1` a pod and the reconciler starts it — you never start a
  container imperatively.

  Each pass reads `Tank.Store.list_pods/0`, diffs it against what's running
  (`Tank.Reconciler.Plan`), and actuates:

    * desired ∧ ¬running            → start a `Tank.Runtime` under the loop's
      `DynamicSupervisor`,
    * running ∧ ¬desired            → stop it,
    * running ∧ desired-but-changed → restart it.

  Resync runs on a timer (the *truth* — manual drift, crashes, and reboots are
  corrected on the next pass) and can be woken early by `nudge/0` (the write
  path calls it, debounced, for low latency). Runtimes are started `:temporary`
  so the reconciler — not the supervisor — owns restart decisions (crash
  handling with backoff lands in a later slice; for now a crashed pod is simply
  restarted on the next resync).

  ## Options

    * `:runtime` — the runtime module (default `Tank.Runtime`); injectable for
      tests.
    * `:owner` — forwarded to each runtime's `:owner` (default: none).
    * `:interval` — resync period in ms (default 5000).
    * `:name` — GenServer name (default `Tank.Reconciler`).
  """

  use GenServer
  require Logger

  alias Tank.{Pod, Store}
  alias Tank.Reconciler.Plan

  @default_interval :timer.seconds(5)
  @debounce 100

  # === API ==================================================================

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Wake the loop early (debounced). Best-effort: a no-op if not running."
  @spec nudge(GenServer.server()) :: :ok
  def nudge(server \\ __MODULE__) do
    GenServer.cast(server, :nudge)
  catch
    :exit, _ -> :ok
  end

  @doc "Force a synchronous resync pass and return. Mainly for tests."
  @spec sync(GenServer.server(), timeout()) :: :ok
  def sync(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :sync, timeout)

  @doc "The pods currently running, as `name => runtime_pid`."
  @spec running(GenServer.server()) :: %{optional(String.t()) => pid()}
  def running(server \\ __MODULE__), do: GenServer.call(server, :running)

  # === lifecycle ============================================================

  @impl true
  def init(opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      sup: sup,
      runtime: Keyword.get(opts, :runtime, Tank.Runtime),
      owner: Keyword.get(opts, :owner),
      interval: Keyword.get(opts, :interval, @default_interval),
      running: %{},
      timer: nil,
      debounce: nil
    }

    # First pass fires as soon as init returns, then the periodic timer.
    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_info(:resync, state) do
    {:noreply, schedule(reconcile(%{state | debounce: nil}), state.interval)}
  end

  # A runtime went down. If we stopped it, we've already demonitored; so this is
  # an unexpected exit — drop it, and the next resync restarts it if still
  # desired.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    running = for {name, info} <- state.running, info.ref != ref, into: %{}, do: {name, info}
    {:noreply, %{state | running: running}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:nudge, state) do
    if state.debounce, do: Process.cancel_timer(state.debounce)
    {:noreply, %{state | debounce: Process.send_after(self(), :resync, @debounce)}}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, schedule(reconcile(state), state.interval)}
  end

  def handle_call(:running, _from, state) do
    {:reply, Map.new(state.running, fn {name, info} -> {name, info.pid} end), state}
  end

  # === the pass =============================================================

  defp reconcile(state) do
    running_specs = Map.new(state.running, fn {name, info} -> {name, info.pod} end)
    plan = Plan.diff(Store.list_pods(), running_specs)

    running =
      state.running
      |> stop_all(plan.stop ++ Enum.map(plan.restart, & &1.name), state)
      |> start_all(plan.start ++ plan.restart, state)

    %{state | running: running}
  end

  defp stop_all(running, names, state), do: Enum.reduce(names, running, &stop_pod(&1, &2, state))

  defp stop_pod(name, running, state) do
    case Map.pop(running, name) do
      {nil, running} ->
        running

      {info, running} ->
        Process.demonitor(info.ref, [:flush])
        DynamicSupervisor.terminate_child(state.sup, info.pid)
        running
    end
  end

  defp start_all(running, pods, state), do: Enum.reduce(pods, running, &start_pod(&1, &2, state))

  defp start_pod(%Pod{} = pod, running, state) do
    child =
      Supervisor.child_spec({state.runtime, {pod, [owner: state.owner]}},
        id: {state.runtime, pod.name},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(state.sup, child) do
      {:ok, pid} ->
        Map.put(running, pod.name, %{pid: pid, ref: Process.monitor(pid), pod: pod})

      {:error, reason} ->
        Logger.error("Tank.Reconciler: failed to start pod #{pod.name}: #{inspect(reason)}")
        running
    end
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :resync, delay)}
  end
end
