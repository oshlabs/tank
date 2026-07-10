defmodule Tank.Runtime.Logs do
  @moduledoc """
  Per-pod log collector: captures container output to disk and to live
  subscribers (`Tank.Logs` is the read/subscribe API and documents the file
  format and configuration).

  Started by `Tank.Runtime` before the workload is spawned. For a non-tty
  container the collector binds two AF_UNIX listeners in the pod's scratch
  dir and hands the runtime `{:connect_unix, _}` stdio directives; linx's
  agent connects them **host-side at spawn time** (before the clone), so the
  paths never need to exist in — or be mounted into — the container's
  rootfs, and the workload just inherits connected fds on 1/2. For a
  `tty: true` container there are no sockets; the runtime tees `:pty_out`
  bytes in via `pty_out/2` (stream `:tty`).

  Bytes are line-buffered per stream; each complete line is stamped,
  appended to `<dir>/<pod>/<container>.log` (size-rotated), and broadcast
  through `Tank.Logs`. On stop the collector drains in-flight socket data
  briefly and flushes any partial line, so a workload's last words survive
  a normal exit.

  One practical constraint: AF_UNIX paths cap at ~107 bytes, so a very deep
  `data_dir` can push the scratch socket paths over the limit — linx then
  fails the spawn fast with `{:error, ENAMETOOLONG, :connect_unix}`.
  """

  use GenServer

  alias Tank.Logs

  # === API =================================================================

  @doc """
  Start a collector for `container` of pod `pod`, or `{:ok, nil}` when
  capture is disabled (`config :tank, :logs, enabled: false`).

  `scratch` hosts the listener sockets (the runtime's per-pod scratch dir —
  wiped on teardown); `data_dir` anchors the default log dir. `overrides`
  are `Tank.Logs.config/2` overrides, used by tests.
  """
  @spec maybe_start(String.t(), String.t(), Path.t(), Path.t(), keyword()) ::
          {:ok, pid() | nil} | {:error, term()}
  def maybe_start(pod, container, scratch, data_dir, overrides \\ []) do
    cfg = Logs.config(data_dir, overrides)

    if cfg.enabled? do
      GenServer.start_link(__MODULE__, {pod, container, scratch, cfg})
    else
      {:ok, nil}
    end
  end

  @doc """
  The stdio directives the workload should be spawned with: stdout/stderr
  each `{:connect_unix, _}` to this collector's listeners, stdin devnull.
  """
  @spec stdio(pid()) :: [{:stdin | :stdout | :stderr, term()}]
  def stdio(collector), do: GenServer.call(collector, :stdio)

  @doc "Tee PTY output (a `tty: true` container's merged stream) into the log."
  @spec pty_out(pid(), binary()) :: :ok
  def pty_out(collector, bytes), do: GenServer.cast(collector, {:data, :tty, bytes})

  @doc "Stop the collector: drain briefly, flush partial lines, close the file."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(collector) do
    if Process.alive?(collector), do: GenServer.stop(collector, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # === GenServer ===========================================================

  @impl true
  def init({pod, container, scratch, cfg}) do
    Process.flag(:trap_exit, true)

    File.mkdir_p!(scratch)
    log_dir = Path.join(cfg.dir, pod)
    File.mkdir_p!(log_dir)

    path = Path.join(log_dir, container <> ".log")
    {:ok, fd} = :file.open(path, [:append, :raw, :binary])

    size =
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    # One listener per captured stream. The workload connects exactly once
    # per fd (at spawn, agent-side); after the handoff the listener closes,
    # so nothing else can ever connect.
    listeners =
      for stream <- [:out, :err], into: %{} do
        sock_path = Path.join(scratch, "log-#{stream}.sock")
        _ = File.rm(sock_path)

        {:ok, listener} =
          :gen_tcp.listen(0, [{:ifaddr, {:local, sock_path}}, :binary, {:active, false}])

        accept_hand_off(listener, stream, self())
        {stream, {listener, sock_path}}
      end

    state = %{
      pod: pod,
      container: container,
      fd: fd,
      path: path,
      size: size,
      max_file_bytes: cfg.max_file_bytes,
      max_files: cfg.max_files,
      listeners: listeners,
      # accepted socket => stream
      socks: %{},
      # per-stream partial line
      buffers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:stdio, _from, state) do
    {_, out_path} = state.listeners.out
    {_, err_path} = state.listeners.err

    directives = [
      stdin: :devnull,
      stdout: {:connect_unix, out_path},
      stderr: {:connect_unix, err_path}
    ]

    {:reply, directives, state}
  end

  @impl true
  def handle_cast({:data, stream, bytes}, state), do: {:noreply, ingest(state, stream, bytes)}

  @impl true
  def handle_info({:accepted, stream, sock}, state) do
    :ok = :inet.setopts(sock, active: true)
    {listener, _path} = Map.fetch!(state.listeners, stream)
    :gen_tcp.close(listener)
    {:noreply, %{state | socks: Map.put(state.socks, sock, stream)}}
  end

  def handle_info({:tcp, sock, data}, state) do
    case Map.fetch(state.socks, sock) do
      {:ok, stream} -> {:noreply, ingest(state, stream, data)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, sock}, state) do
    # EOF: the workload exited (or aborted). Flush that stream's partial line.
    case Map.pop(state.socks, sock) do
      {nil, _} -> {:noreply, state}
      {stream, socks} -> {:noreply, %{flush_partial(state, stream) | socks: socks}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # In-flight bytes may still be queued (kernel buffer → message queue):
    # drain until 100 ms of silence, bounded. The workload is already gone
    # (or being torn down) when we're stopped, so this terminates quickly.
    state = drain(state, 50)
    state = Enum.reduce(Map.keys(state.buffers), state, &flush_partial(&2, &1))
    :file.close(state.fd)
    :ok
  end

  defp drain(state, 0), do: state

  defp drain(state, tries) do
    receive do
      {:tcp, sock, data} ->
        case Map.fetch(state.socks, sock) do
          {:ok, stream} -> drain(ingest(state, stream, data), tries - 1)
          :error -> drain(state, tries - 1)
        end

      {:accepted, _stream, _sock} ->
        drain(state, tries - 1)

      {:tcp_closed, _sock} ->
        drain(state, tries - 1)
    after
      100 -> state
    end
  end

  # === capture =============================================================

  # Hand an accepted socket to the collector. Blocking accept in a linked
  # helper; a listener closed before anything connected (teardown, or a tty
  # pod whose sockets are never used) ends the helper silently.
  defp accept_hand_off(listener, stream, collector) do
    spawn_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, sock} ->
          :ok = :gen_tcp.controlling_process(sock, collector)
          send(collector, {:accepted, stream, sock})

        {:error, _closed} ->
          :ok
      end
    end)
  end

  defp ingest(state, stream, data) do
    buffered = Map.get(state.buffers, stream, "") <> data
    {complete, rest} = String.split(buffered, "\n") |> Enum.split(-1)
    state = Enum.reduce(complete, state, &write_line(&2, stream, &1))
    %{state | buffers: Map.put(state.buffers, stream, hd(rest))}
  end

  defp flush_partial(state, stream) do
    case Map.get(state.buffers, stream, "") do
      "" ->
        state

      partial ->
        state = write_line(state, stream, partial)
        %{state | buffers: Map.put(state.buffers, stream, "")}
    end
  end

  defp write_line(state, stream, line) do
    # PTY output arrives CRLF-terminated (ONLCR); the split ate the \n, so
    # shed the \r too. Harmless for out/err, where a stray \r is noise anyway.
    line = String.replace_suffix(line, "\r", "")
    ts = DateTime.utc_now()
    record = [DateTime.to_iso8601(ts), " ", Atom.to_string(stream), " ", line, "\n"]
    record_size = IO.iodata_length(record)

    state =
      if state.size > 0 and state.size + record_size > state.max_file_bytes,
        do: rotate(state),
        else: state

    :ok = :file.write(state.fd, record)

    Logs.broadcast(state.pod, %{
      container: state.container,
      stream: stream,
      ts: ts,
      line: line
    })

    %{state | size: state.size + record_size}
  end

  # <c>.log → <c>.log.1 → … → <c>.log.<max-1> → dropped. The fd is reopened
  # fresh, so rename-based rotation is safe (no writer left on the old inode).
  defp rotate(state) do
    :file.close(state.fd)

    _ = File.rm(state.path <> ".#{state.max_files - 1}")

    if state.max_files >= 3 do
      for i <- (state.max_files - 2)..1//-1 do
        _ = File.rename(state.path <> ".#{i}", state.path <> ".#{i + 1}")
      end
    end

    _ = File.rename(state.path, state.path <> ".1")

    {:ok, fd} = :file.open(state.path, [:append, :raw, :binary])
    %{state | fd: fd, size: 0}
  end
end
