defmodule Tank.Logs do
  @moduledoc """
  Reading and following container logs.

  Capture is done by `Tank.Runtime.Logs` (one collector per pod, started by
  the pod's runtime): a non-tty container's stdout/stderr are wired to the
  collector over AF_UNIX sockets (`{:connect_unix, _}` stdio — linx connects
  them host-side at spawn time, so the pod's rootfs pivot never sees them);
  a `tty: true` container's merged PTY output is teed in by the runtime.
  Lines land in one file per container, under one directory per pod, with a
  fixed prefix:

      2026-07-10T12:34:56.123456Z out GET /healthz 200
      ^ UTC ISO 8601               ^ stream: out | err | tty

  This module is the read side:

    * `tail/2` — the last N parsed entries for a pod, from disk. Works
      whether or not the pod is running.
    * `subscribe/1` / `unsubscribe/1` — live entries as they are captured,
      delivered as `{:tank_logs, pod, entry}` messages.

  An *entry* is `%{container: String.t(), stream: :out | :err | :tty,
  ts: DateTime.t(), line: binary()}`.

  ## Configuration

      config :tank, :logs,
        # Where log files live; default: <data_dir>/logs.
        dir: "/var/lib/tank/logs",
        # Size-based rotation: when the current file would exceed this,
        # it becomes <file>.1 (older files shift up; the oldest drops).
        max_file_bytes: 5_000_000,
        # Total files kept per container (current + rotated). Min 2.
        max_files: 5,
        # Set false to restore the pre-capture behaviour (stdio → /dev/null).
        enabled: true

  Files append across pod restarts and respecs (they are pod-name-keyed,
  like managed volumes) and are removed with nothing — cleanup is the
  operator's call for now.

  ## Caveats (v0)

    * While a `tty: true` container is **attached** (`Tank.attach/1`), PTY
      bytes flow to the attacher, not the collector — interactive sessions
      leave a gap in the log.
    * Capture rides the pod's lifecycle: bytes the workload writes in the
      instant the runtime is torn down can be lost (the collector drains
      briefly on stop, so in practice the tail survives normal exits).
    * A line is capped at 16 KiB: a stream that never emits a newline is
      force-flushed in 16 KiB slices, so an entry's `line` may be a
      fragment of a longer write.
  """

  @registry Tank.Logs.Registry

  @type stream :: :out | :err | :tty
  @type entry :: %{container: String.t(), stream: stream(), ts: DateTime.t(), line: binary()}

  @doc false
  def registry, do: @registry

  @doc """
  The last `:tail` entries (default 200) for `pod`, oldest first.

  Reads the pod's log files (including one rotation back per container when
  the current file is short), parses the line prefix, and merges containers
  by timestamp. A pod with no logs yields `{:ok, []}`.

  Options: `:tail` — max entries; `:dir` — override the configured log dir.
  """
  @spec tail(String.t(), keyword()) :: {:ok, [entry()]}
  def tail(pod, opts \\ []) when is_binary(pod) do
    n = Keyword.get(opts, :tail, 200)
    pod_dir = Path.join(Keyword.get(opts, :dir) || dir(), pod)

    entries =
      case File.ls(pod_dir) do
        {:error, _} ->
          []

        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".log"))
          |> Enum.flat_map(&read_container_tail(pod_dir, &1, n))
          |> Enum.sort_by(& &1.ts, DateTime)
          |> take_last(n)
      end

    {:ok, entries}
  end

  @doc """
  Follow a pod's log live: the caller receives `{:tank_logs, pod, entry}`
  for every captured line until `unsubscribe/1` (or the caller exits —
  registrations are process-scoped).
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(pod) when is_binary(pod) do
    {:ok, _} = Registry.register(@registry, pod, nil)
    :ok
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(pod) when is_binary(pod) do
    Registry.unregister(@registry, pod)
  end

  @doc false
  # Broadcast one captured entry to `subscribe/1`-ers. Called by the collector.
  @spec broadcast(String.t(), entry()) :: :ok
  def broadcast(pod, entry) do
    Registry.dispatch(@registry, pod, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:tank_logs, pod, entry})
    end)
  end

  @doc false
  # Effective capture config. `data_dir` anchors the default :dir; explicit
  # overrides (used by tests) win over the application env.
  @spec config(Path.t(), keyword()) :: %{
          enabled?: boolean(),
          dir: Path.t(),
          max_file_bytes: pos_integer(),
          max_files: pos_integer()
        }
  def config(data_dir, overrides \\ []) do
    cfg = Keyword.merge(Application.get_env(:tank, :logs, []), overrides)

    %{
      enabled?: Keyword.get(cfg, :enabled, true),
      dir: Keyword.get(cfg, :dir) || Path.join(data_dir, "logs"),
      max_file_bytes: Keyword.get(cfg, :max_file_bytes, 5_000_000),
      # < 2 would make "rotate" mean "truncate"; keep the invariant simple.
      max_files: max(Keyword.get(cfg, :max_files, 5), 2)
    }
  end

  # The configured log dir for reads, resolved the same way the collector
  # resolves it at capture time.
  defp dir do
    config(Application.get_env(:tank, :data_dir) || Path.join(System.tmp_dir!(), "tank")).dir
  end

  # --- file parsing -----------------------------------------------------

  # Tail of one container: the current file, topped up from its most recent
  # rotation when the current file alone can't fill `n`.
  defp read_container_tail(pod_dir, file, n) do
    container = Path.basename(file, ".log")
    path = Path.join(pod_dir, file)
    current = parse_file(path, container)

    if length(current) >= n do
      take_last(current, n)
    else
      take_last(parse_file(path <> ".1", container) ++ current, n)
    end
  end

  defp parse_file(path, container) do
    case File.read(path) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case parse_line(container, line) do
            nil -> []
            entry -> [entry]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_line(container, line) do
    with [ts, stream, rest] <- String.split(line, " ", parts: 3),
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts),
         {:ok, stream} <- parse_stream(stream) do
      %{container: container, stream: stream, ts: dt, line: rest}
    else
      # A malformed line (e.g. torn by a crash mid-write) is skipped, not fatal.
      _ -> nil
    end
  end

  defp parse_stream("out"), do: {:ok, :out}
  defp parse_stream("err"), do: {:ok, :err}
  defp parse_stream("tty"), do: {:ok, :tty}
  defp parse_stream(_), do: :error

  defp take_last(list, n), do: Enum.take(list, -n)
end
