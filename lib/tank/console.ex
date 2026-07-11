defmodule Tank.Console do
  @moduledoc """
  Web-capable exec/attach: PTY sessions whose bytes flow as messages, not
  through a terminal.

  Where `Tank.exec/3` and `Tank.attach/1` pump the *calling process's* real
  terminal (via `Linx.Tty` — the iex/SSH path), a console session is owned
  by a dedicated process and hands its output to a `:consumer` (a LiveView,
  a Channel, any pid):

      {:ok, session} = Tank.Console.exec("web", ["/bin/sh"], cols: 120, rows: 30)
      Tank.Console.write(session, "echo hi\\n")
      # consumer receives {:tank_console, session, {:data, "hi\\r\\n"}}
      Tank.Console.resize(session, 100, 40)
      Tank.Console.close(session)

  Consumer messages:

    * `{:tank_console, session, {:data, bytes}}` — PTY output.
    * `{:tank_console, session, {:exit, {:exited, code} | {:signaled, n}}}` —
      the program ended; the session stops.
    * `{:tank_console, session, :closed}` — the session ended without the
      program ending (detach/close). Exec's entered process is stopped with
      it; an attached pod keeps running.

  The session monitors its consumer — a vanished LiveView closes the session
  (detaching, never killing an attached pod). Output floods are shed rather
  than queued without bound: when the consumer's mailbox lags, chunks are
  dropped and a `[tank: output dropped]` marker is emitted once it drains.

  Attach reuses `Tank.Runtime`'s `begin_attach`/`end_attach` ownership
  handoff (second attacher → `{:error, :attached}`) and tees the bytes into
  the pod's log collector — unlike a CLI attach, a web attach leaves no gap
  in `Tank.logs/2`.
  """

  require Logger

  alias Tank.{Reconciler, Runtime}
  alias Tank.Console.Session

  @type session :: pid()

  @doc """
  Run `argv` as a new PTY'd process inside `pod` (web `docker exec`).

  Options: `:consumer` (default: the caller), `:cols`/`:rows` (initial
  winsize), `:cwd`, `:env` (same semantics as `Tank.exec/3`).
  """
  @spec exec(String.t(), [String.t()], keyword()) :: {:ok, session()} | {:error, term()}
  def exec(pod, argv, opts \\ []) when is_binary(pod) and is_list(argv) and argv != [] do
    start_session({:exec, pod, argv, with_consumer(opts)})
  end

  @doc """
  Attach to a `tty: true` pod's main process (web `docker attach`).

  Options: `:consumer`, `:cols`/`:rows`. `{:error, :not_running}`,
  `{:error, :not_a_tty}`, or `{:error, :attached}` (someone else holds it).
  """
  @spec attach(String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def attach(pod, opts \\ []) when is_binary(pod) do
    start_session({:attach, pod, with_consumer(opts)})
  end

  @doc "Write keystrokes/bytes to the session's PTY."
  @spec write(session(), iodata()) :: :ok | {:error, term()}
  def write(session, bytes), do: GenServer.call(session, {:write, IO.iodata_to_binary(bytes)})

  @doc "Resize the PTY (browser terminal resized)."
  @spec resize(session(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(session, cols, rows) when is_integer(cols) and is_integer(rows),
    do: GenServer.call(session, {:resize, cols, rows})

  @doc "Hand the session's output to a different consumer (LiveView reconnect)."
  @spec set_consumer(session(), pid()) :: :ok
  def set_consumer(session, consumer) when is_pid(consumer),
    do: GenServer.call(session, {:set_consumer, consumer})

  @doc """
  End the session: an exec's entered process is stopped; an attached pod is
  detached and keeps running. Best-effort — `:ok` if already gone.
  """
  @spec close(session()) :: :ok
  def close(session) do
    GenServer.stop(session, :normal)
  catch
    :exit, _ -> :ok
  end

  defp with_consumer(opts), do: Keyword.put_new(opts, :consumer, self())

  defp start_session(spec) do
    DynamicSupervisor.start_child(Tank.Console.Supervisor, {Session, spec})
  end

  # === shared exec plumbing (also used by Tank.exec/3) ======================

  @doc false
  # Resolve a pod name to its container's exec context (host pid + env + cwd)
  # via the reconciler's view of what's running and the owning Tank.Runtime.
  def resolve_exec_context(pod_name) do
    case Map.fetch(running(), pod_name) do
      {:ok, runtime} -> Runtime.exec_context(runtime)
      :error -> {:error, :not_running}
    end
  end

  @doc false
  def resolve_runtime(pod_name) do
    case Map.fetch(running(), pod_name) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:error, :not_running}
    end
  end

  defp running do
    Reconciler.running()
  catch
    :exit, _ -> %{}
  end

  @doc false
  # auto_proceed: false — the entered process parks at Linx's checkpoint so
  # the caller can put it into the pod's cgroup *before* it execs (accounting
  # and limits apply to exec'd sessions, docker-exec style). Every caller must
  # join_pod_cgroup/2 + proceed/1 on {:linx_process, :ready, host_pid}.
  def enter_opts(ctx, argv, opts) do
    [
      argv: argv,
      stdio: :pty,
      auto_proceed: false,
      cwd: Keyword.get(opts, :cwd, ctx.working_dir),
      env: exec_env(ctx.env, Keyword.get(opts, :env, []))
    ]
  end

  @doc false
  # Put an entered (exec'd) process into the pod's cgroup, pre-exec. A pod
  # without a cgroup already "runs unaccounted" (see Tank.Runtime.Limits) —
  # its execs then do too; a failed join is only ever loud, never fatal.
  def join_pod_cgroup(%{cgroup: cgroup}, host_pid) when is_binary(cgroup) do
    case Linx.Cgroup.add_process(cgroup, host_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Tank.Console: exec pid #{host_pid} not joined to #{cgroup} " <>
            "(#{inspect(reason)}); it runs unaccounted and uncapped"
        )

        :ok
    end
  end

  def join_pod_cgroup(_ctx, _host_pid), do: :ok

  # The container's env, a default TERM when it set none (for a usable shell),
  # then the caller's :env overrides merged on top -- last writer per key wins.
  @doc false
  def exec_env(container_env, overrides) do
    has_term? = Enum.any?(container_env, &String.starts_with?(&1, "TERM="))
    base = if has_term?, do: container_env, else: ["TERM=xterm" | container_env]
    merge_env(base, overrides)
  end

  defp merge_env(base, overrides) do
    over_keys = MapSet.new(overrides, &env_key/1)
    Enum.reject(base, &MapSet.member?(over_keys, env_key(&1))) ++ overrides
  end

  defp env_key(kv), do: kv |> String.split("=", parts: 2) |> hd()
end
