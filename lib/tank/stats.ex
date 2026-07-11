defmodule Tank.Stats do
  @moduledoc """
  Per-pod runtime statistics: realtime samples plus a bounded in-memory
  history.

  A sampler polls every running pod (default every 2s): cpu/memory/pids from
  the pod's cgroup (`/sys/fs/cgroup/tank/<name>` — created for every pod,
  see `Tank.Runtime.Limits`) and interface counters from inside the pod's
  netns (rtnetlink `RTM_GETSTATS` via the workload's host pid; skipped for
  `network: :host`, whose counters aren't pod-attributable). Rates
  (`cpu_percent`, `rx/tx_bytes_per_sec`) are derived between consecutive
  samples and reset across a pod restart.

  History is two ETS rings: raw samples for a short window (default 2s ×
  10min) and coarse folded samples for a longer one (default 1min × 4h).
  Nothing persists — history dies with the BEAM (the recorded trade-off; an
  on-disk round-robin store is the later upgrade).

      Tank.stats("web")                        # newest sample
      Tank.stats("web", window: :timer.minutes(5))   # oldest-first history
      Tank.Stats.subscribe("web")              # {:tank_event, {:stats, "web"}, sample}

  ## Configuration

      config :tank, :stats,
        enabled: true,
        interval: 2_000,
        raw_window: :timer.minutes(10),
        coarse_interval: :timer.minutes(1),
        coarse_window: :timer.hours(4)

  Fields a source couldn't provide are `nil` (cgroup missing on an exotic
  system, netns unreadable without privileges) — a sample is still emitted
  so the UI can render honestly.
  """

  use GenServer
  require Logger

  alias Linx.Netlink.Rtnl
  alias Tank.Events
  alias Tank.Stats.Ring

  @table :tank_stats
  @cgroup_root "/sys/fs/cgroup/tank"

  @typedoc "One sampling tick's worth of a pod's counters and derived rates."
  @type sample :: %{
          pod: String.t(),
          at: DateTime.t(),
          cpu_usec: non_neg_integer() | nil,
          cpu_percent: float() | nil,
          memory_bytes: non_neg_integer() | nil,
          memory_peak_bytes: non_neg_integer() | nil,
          pids: non_neg_integer() | nil,
          net:
            %{optional(String.t()) => %{rx_bytes: non_neg_integer(), tx_bytes: non_neg_integer()}}
            | nil,
          rx_bytes_per_sec: float() | nil,
          tx_bytes_per_sec: float() | nil
        }

  # === API ==================================================================

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The newest sample for `pod`."
  @spec current(String.t()) :: {:ok, sample()} | {:error, :not_found}
  def current(pod) when is_binary(pod) do
    Ring.current(@table, pod)
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Oldest-first history for `pod`. `window: ms` picks the resolution: raw
  samples while the raw ring covers the window, coarse otherwise. A pod too
  young to have folded a coarse bucket falls back to the raw ring rather
  than answering an empty history.
  """
  @spec history(String.t(), keyword()) :: [sample()]
  def history(pod, opts \\ []) when is_binary(pod) do
    window = Keyword.get(opts, :window, :timer.minutes(10))
    cfg = config()

    resolution = if window <= cfg.interval * cfg.raw_cap, do: :raw, else: :coarse
    cutoff = DateTime.add(DateTime.utc_now(), -window, :millisecond)
    in_window = fn samples -> Enum.filter(samples, &(DateTime.compare(&1.at, cutoff) != :lt)) end

    case in_window.(Ring.samples(@table, pod, resolution)) do
      [] when resolution == :coarse -> in_window.(Ring.samples(@table, pod, :raw))
      samples -> samples
    end
  rescue
    ArgumentError -> []
  end

  @doc "Live samples: `{:tank_event, {:stats, pod}, sample}` per tick."
  @spec subscribe(String.t()) :: :ok
  def subscribe(pod) when is_binary(pod), do: Events.subscribe({:stats, pod})

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(pod) when is_binary(pod), do: Events.unsubscribe({:stats, pod})

  @doc false
  # Effective config; `overrides` (start_link opts, used by tests) win over
  # the application env.
  def config(overrides \\ []) do
    cfg = Keyword.merge(Application.get_env(:tank, :stats, []), overrides)
    interval = Keyword.get(cfg, :interval, 2_000)
    coarse_interval = Keyword.get(cfg, :coarse_interval, :timer.minutes(1))

    %{
      enabled?: Keyword.get(cfg, :enabled, true),
      interval: interval,
      raw_cap: max(div(Keyword.get(cfg, :raw_window, :timer.minutes(10)), interval), 1),
      coarse_interval: coarse_interval,
      coarse_cap: max(div(Keyword.get(cfg, :coarse_window, :timer.hours(4)), coarse_interval), 1)
    }
  end

  # === sampler ==============================================================

  @impl true
  def init(opts) do
    cfg = config(opts)

    :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    Events.subscribe(:pods)

    state = %{
      cfg: cfg,
      # pod => %{at_ms, host_pid, cpu_usec, rx_bytes, tx_bytes} — the previous
      # raw readings that rates derive from.
      prev: %{},
      # pod => next raw seq
      seq: %{},
      # pod => raw samples accumulated toward the next coarse fold
      bucket: %{},
      coarse_seq: %{},
      last_fold: now_ms()
    }

    schedule(cfg.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    schedule(state.cfg.interval)
    state = state |> sample_all() |> maybe_fold()
    {:noreply, state}
  end

  # Pod left desired state: drop its rows and derivation state.
  def handle_info({:tank_event, :pods, %{status: :deleted, name: name}}, state) do
    Ring.delete_pod(@table, name)

    {:noreply,
     %{
       state
       | prev: Map.delete(state.prev, name),
         seq: Map.delete(state.seq, name),
         bucket: Map.delete(state.bucket, name),
         coarse_seq: Map.delete(state.coarse_seq, name)
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp sample_all(state) do
    running_pods()
    |> Enum.reduce(state, fn pod_status, state -> sample_one(pod_status, state) end)
  end

  defp running_pods do
    for %{status: :running} = ps <- Tank.status(), is_integer(ps.host_pid), do: ps
  catch
    :exit, _ -> []
  end

  defp sample_one(%{pod: pod, host_pid: host_pid}, state) do
    name = pod.name
    at_ms = now_ms()
    cg = cgroup_stats(name)
    net = net_stats(pod, host_pid)

    prev = state.prev[name]
    # A restarted workload has fresh counters: derive only against the same
    # incarnation (same host_pid).
    prev = if prev && prev.host_pid == host_pid, do: prev, else: nil

    {rx, tx} = totals(net)

    sample = %{
      pod: name,
      at: DateTime.utc_now(),
      cpu_usec: cg[:cpu_usec],
      cpu_percent: rate(cg[:cpu_usec], prev[:cpu_usec], at_ms, prev[:at_ms], &cpu_percent/2),
      memory_bytes: cg[:memory_current],
      memory_peak_bytes: cg[:memory_peak],
      pids: cg[:pids_current],
      net: net,
      rx_bytes_per_sec: rate(rx, prev[:rx_bytes], at_ms, prev[:at_ms], &per_second/2),
      tx_bytes_per_sec: rate(tx, prev[:tx_bytes], at_ms, prev[:at_ms], &per_second/2)
    }

    seq = Map.get(state.seq, name, 0)
    Ring.put_current(@table, name, sample)
    Ring.insert(@table, name, :raw, seq, sample, state.cfg.raw_cap)
    Events.broadcast({:stats, name}, sample)

    %{
      state
      | prev:
          Map.put(state.prev, name, %{
            at_ms: at_ms,
            host_pid: host_pid,
            cpu_usec: cg[:cpu_usec],
            rx_bytes: rx,
            tx_bytes: tx
          }),
        seq: Map.put(state.seq, name, seq + 1),
        bucket: Map.update(state.bucket, name, [sample], &[sample | &1])
    }
  end

  defp maybe_fold(state) do
    if now_ms() - state.last_fold >= state.cfg.coarse_interval do
      coarse_seq =
        Enum.reduce(state.bucket, state.coarse_seq, fn {pod, samples}, acc ->
          case Ring.fold(Enum.reverse(samples)) do
            nil ->
              acc

            folded ->
              seq = Map.get(acc, pod, 0)
              Ring.insert(@table, pod, :coarse, seq, folded, state.cfg.coarse_cap)
              Map.put(acc, pod, seq + 1)
          end
        end)

      %{state | bucket: %{}, coarse_seq: coarse_seq, last_fold: now_ms()}
    else
      state
    end
  end

  # === sources ==============================================================

  defp cgroup_stats(name) do
    case Linx.Cgroup.stats(Path.join(@cgroup_root, name)) do
      {:ok, stats} -> Map.from_struct(stats)
      {:error, _} -> %{}
    end
  end

  # Interface counters from inside the pod's netns. :host pods are skipped
  # (the host's counters aren't the pod's); failures (no privileges, pod
  # mid-teardown) yield nil rather than noise.
  defp net_stats(%{network: :host}, _host_pid), do: nil

  defp net_stats(_pod, host_pid) do
    case Rtnl.open({:pid, host_pid}) do
      {:ok, socket} ->
        try do
          with {:ok, links} <- Rtnl.Link.list(socket),
               {:ok, stats} <- Rtnl.Stats.list(socket) do
            names = Map.new(links, &{&1.index, &1.name})

            for s <- stats,
                name = names[s.ifindex],
                name && name != "lo",
                s.link,
                into: %{} do
              {name, %{rx_bytes: s.link.rx_bytes || 0, tx_bytes: s.link.tx_bytes || 0}}
            end
          else
            _ -> nil
          end
        after
          Linx.Netlink.Socket.close(socket)
        end

      {:error, _} ->
        nil
    end
  end

  defp totals(nil), do: {nil, nil}

  defp totals(net) do
    {net |> Enum.map(fn {_, c} -> c.rx_bytes end) |> Enum.sum(),
     net |> Enum.map(fn {_, c} -> c.tx_bytes end) |> Enum.sum()}
  end

  # A derived rate needs both a current and a comparable previous reading.
  defp rate(cur, prev, at_ms, prev_at_ms, f)
       when is_integer(cur) and is_integer(prev) and is_integer(prev_at_ms) and
              at_ms > prev_at_ms do
    f.(cur - prev, at_ms - prev_at_ms)
  end

  defp rate(_cur, _prev, _at_ms, _prev_at_ms, _f), do: nil

  # cpu.stat usage is µs of cpu per wall ms → percent (can exceed 100 on
  # multicore, deliberately).
  defp cpu_percent(dusec, dms), do: dusec / (dms * 1000) * 100.0

  defp per_second(dbytes, dms), do: dbytes * 1000 / dms

  defp schedule(interval), do: Process.send_after(self(), :sample, interval)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
