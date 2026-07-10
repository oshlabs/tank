defmodule Tank.Reconciler do
  @moduledoc """
  The level-triggered control loop that converges running pods to the desired
  state in `Tank.Store`. This is what closes the declarative loop: you
  `Tank.apply/1` a pod and the reconciler starts it — you never start a
  container imperatively.

  Each pass reads `Tank.Store.list_pods/0`, diffs it against what's tracked,
  and actuates:

    * desired ∧ ¬tracked            → start a `Tank.Runtime` under the loop's
      `DynamicSupervisor`,
    * tracked ∧ ¬desired            → stop it,
    * tracked ∧ desired-but-changed → restart it with the new spec.

  Resync runs on a timer (the *truth* — drift, crashes, reboots are corrected on
  the next pass) and can be woken early by `nudge/0` (the write path calls it,
  debounced). Runtimes are started `:temporary`, so the reconciler — not the
  supervisor — owns restart.

  ## Crash handling

  Each pod carries a status: `:running`, `:backing_off`, or `:terminal`. When a
  runtime exits unexpectedly, the loop honours the pod's `:restart` policy
  (`:always`; `:on_failure` only on an abnormal exit; `:never`):

    * restartable → wait `min(base · 2ⁿ, cap)` then restart (status
      `:backing_off`); `n` resets after a stable run, so a crash loop backs off
      while an occasional crash recovers fast.
    * not restartable → status `:terminal`; resync leaves it stopped (until its
      spec changes or it is deleted).

  ## Options

    * `:runtime` — the runtime module (default `Tank.Runtime`); injectable for tests.
    * `:owner` — forwarded to each runtime's `:owner` (default: none).
    * `:runtime_opts` — extra opts merged into each runtime's start (e.g.
      `[image: [cache: …]]`).
    * `:interval` — resync period in ms (default 5000).
    * `:backoff_base` / `:backoff_cap` — restart backoff bounds in ms
      (defaults 10_000 / 300_000, per the PLAN).
    * `:stable_window` — a run lasting at least this long (ms) resets the
      backoff (default 600_000).
    * `:name` — GenServer name (default `Tank.Reconciler`).
  """

  use GenServer
  require Logger

  alias Tank.{Pod, Store}
  alias Tank.Reconciler.Plan

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

  @doc "Each tracked pod's `%{status:, retries:}`. Mainly for introspection/tests."
  @spec status(GenServer.server()) :: %{optional(String.t()) => map()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # === lifecycle ============================================================

  @impl true
  def init(opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      sup: sup,
      runtime: Keyword.get(opts, :runtime, Tank.Runtime),
      owner: Keyword.get(opts, :owner),
      runtime_opts: Keyword.get(opts, :runtime_opts, []),
      interval: Keyword.get(opts, :interval, :timer.seconds(5)),
      backoff_base: Keyword.get(opts, :backoff_base, :timer.seconds(10)),
      backoff_cap: Keyword.get(opts, :backoff_cap, :timer.minutes(5)),
      stable_window: Keyword.get(opts, :stable_window, :timer.minutes(10)),
      timer: nil,
      debounce: nil,
      # name => %{pod, status, pid, ref, retries, start_at, restart_timer}
      pods: %{}
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_info(:resync, state) do
    {:noreply, schedule(reconcile(%{state | debounce: nil}), state.interval)}
  end

  # A runtime exited on its own (we demonitor before any intentional stop, so
  # this is always unexpected). Honour the restart policy.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_by_ref(state.pods, ref) do
      nil -> {:noreply, state}
      {name, entry} -> {:noreply, %{state | pods: on_exit(name, entry, reason, state)}}
    end
  end

  # A backoff timer fired: restart the pod if it is still backing off.
  def handle_info({:restart, name}, state) do
    case state.pods[name] do
      %{status: :backing_off, pod: pod, retries: retries} ->
        {:noreply, %{state | pods: do_start(pod, retries, state.pods, state)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:nudge, state) do
    if state.debounce, do: Process.cancel_timer(state.debounce)
    {:noreply, %{state | debounce: Process.send_after(self(), :resync, 100)}}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, schedule(reconcile(state), state.interval)}
  end

  def handle_call(:running, _from, state) do
    running = for {name, %{status: :running, pid: pid}} <- state.pods, into: %{}, do: {name, pid}
    {:reply, running, state}
  end

  def handle_call(:status, _from, state) do
    status =
      Map.new(state.pods, fn {name, e} -> {name, %{status: e.status, retries: e.retries}} end)

    {:reply, status, state}
  end

  # === the pass =============================================================

  defp reconcile(state) do
    desired = Store.list_pods()
    plan = Plan.diff(desired, tracked_specs(state.pods))

    pods =
      state.pods
      |> stop_pods(plan.stop ++ Enum.map(plan.restart, & &1.name), state)
      |> start_pods(plan.restart ++ plan.start, state)

    # Level-triggered like the rest of the pass: any IPAM allocation whose pod
    # has left desired state is released, even if its teardown was missed.
    Tank.Ipam.reconcile(Enum.map(desired, & &1.name))

    %{state | pods: pods}
  end

  defp tracked_specs(pods), do: Map.new(pods, fn {name, e} -> {name, e.pod} end)

  defp stop_pods(pods, names, state), do: Enum.reduce(names, pods, &stop_pod(&1, &2, state))

  defp stop_pod(name, pods, state) do
    case Map.pop(pods, name) do
      {nil, pods} -> pods
      {entry, pods} -> teardown(entry, state) && pods
    end
  end

  defp teardown(entry, state) do
    if entry.ref, do: Process.demonitor(entry.ref, [:flush])
    if entry.restart_timer, do: Process.cancel_timer(entry.restart_timer)

    if entry.status == :running and is_pid(entry.pid),
      do: DynamicSupervisor.terminate_child(state.sup, entry.pid)

    true
  end

  defp start_pods(pods, specs, state),
    do: Enum.reduce(specs, pods, fn pod, acc -> do_start(pod, 0, acc, state) end)

  defp do_start(%Pod{} = pod, retries, pods, state) do
    runtime_opts = Keyword.merge(state.runtime_opts, owner: state.owner)

    child =
      Supervisor.child_spec({state.runtime, {pod, runtime_opts}},
        id: {state.runtime, pod.name},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(state.sup, child) do
      {:ok, pid} ->
        entry = %{
          pod: pod,
          status: :running,
          pid: pid,
          ref: Process.monitor(pid),
          retries: retries,
          start_at: now(),
          restart_timer: nil
        }

        Map.put(pods, pod.name, entry)

      {:error, reason} ->
        # Leave it untracked; the next resync retries the start.
        Logger.error("Tank.Reconciler: failed to start pod #{pod.name}: #{inspect(reason)}")
        Map.delete(pods, pod.name)
    end
  end

  # === crash handling =======================================================

  defp on_exit(name, entry, reason, state) do
    if restart?(entry.pod, reason) do
      # A run that lasted the stable window resets the backoff to base (2⁰).
      n = if stable?(entry, state), do: 0, else: entry.retries
      delay = min(state.backoff_base * Integer.pow(2, n), state.backoff_cap)
      timer = Process.send_after(self(), {:restart, name}, delay)

      Map.put(state.pods, name, %{
        entry
        | status: :backing_off,
          pid: nil,
          ref: nil,
          retries: n + 1,
          restart_timer: timer
      })
    else
      Map.put(state.pods, name, %{
        entry
        | status: :terminal,
          pid: nil,
          ref: nil,
          restart_timer: nil
      })
    end
  end

  defp stable?(%{start_at: start_at}, state),
    do: now() - (start_at || now()) >= state.stable_window

  defp restart?(%Pod{restart: :always}, _reason), do: true
  defp restart?(%Pod{restart: :on_failure}, :normal), do: false
  defp restart?(%Pod{restart: :on_failure}, _reason), do: true
  defp restart?(%Pod{restart: :never}, _reason), do: false

  # === helpers ==============================================================

  defp find_by_ref(pods, ref) do
    Enum.find_value(pods, fn {name, entry} -> if entry.ref == ref, do: {name, entry} end)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :resync, delay)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
