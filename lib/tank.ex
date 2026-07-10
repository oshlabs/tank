defmodule Tank do
  @moduledoc """
  Tank — an opinionated, declarative container orchestrator built on Linx.

  You describe the pods that should run as Elixir data; Tank persists that
  desired state in Khepri and a level-triggered loop converges the machine to
  it. This module is the **runtime write API** over the desired state:

      Tank.apply(%{
        name: "web",
        containers: [%{name: "app", image: "nginx:1.27"}]
      })

      Tank.list()        #=> [%Tank.Pod{name: "web", …}]
      Tank.delete("web")

  `apply/1` accepts a `%Tank.Pod{}` or a plain spec map (validated via
  `Tank.Pod.new/1`); it writes to `[:tank, :pods, name]` in the store. You never
  imperatively start a container — you state intent and the reconciler converges.

  ## Architecture

    * `Tank.Pod` and friends — the typed desired-state model.
    * `Tank.Store` — the Khepri seam (the source of truth) + an ETS projection.
    * `Tank.Runtime` — the per-container actuator (`Linx.Process` + `Rtnl`),
      the M2 proof of concept that M4 grows into the pod actuator.

  Tank is a separate mix app with a *path* dependency on Linx, so it reaches
  **only Linx's public API**; a gap in the primitives surfaces here, early.

  ## Bootstrap vs. runtime

  Khepri is the source of truth. `config/runtime.exs` only *seeds* pods
  create-if-absent on a fresh store, so the boot seed never clobbers state
  changed at runtime via `apply/1` / `delete/1`.
  """

  require Logger

  alias Tank.{Pod, Reconciler, Runtime, Store}

  @type spec :: Pod.t() | map() | keyword()

  @doc """
  Declare a pod's desired state — create it or replace it. Accepts a
  `%Tank.Pod{}` or a spec map/keyword list (validated via `Tank.Pod.new/1`).
  """
  @spec apply(spec()) :: :ok | {:error, term()}
  def apply(spec) do
    with {:ok, pod} <- to_pod(spec),
         :ok <- Store.put_pod(pod) do
      Tank.Events.broadcast(:pods, %{name: pod.name, status: :applied, at: DateTime.utc_now()})
      nudge()
    end
  end

  @doc "Remove a pod's desired state, by name or by `%Tank.Pod{}`."
  @spec delete(String.t() | Pod.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    with :ok <- Store.delete_pod(name) do
      Tank.Events.broadcast(:pods, %{name: name, status: :deleted, at: DateTime.utc_now()})
      nudge()
    end
  end

  def delete(%Pod{name: name}), do: delete(name)

  @doc """
  Stop a pod's workload and start it fresh — retries reset, backoff cleared.
  The desired state is untouched. `{:error, :not_found}` for an undeclared
  pod; `{:error, :unavailable}` when the reconciler isn't running.
  """
  @spec restart(String.t()) :: :ok | {:error, :not_found | :unavailable}
  def restart(name) when is_binary(name) do
    Reconciler.restart_pod(name)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Fetch one declared pod by name."
  @spec get(String.t()) :: {:ok, Pod.t()} | {:error, :not_found}
  def get(name) when is_binary(name), do: Store.get_pod(name)

  @doc "Every declared pod (a fast read through the store's projection)."
  @spec list() :: [Pod.t()]
  def list, do: Store.list_pods()

  @typedoc """
  Desired ∪ observed: the declared pod plus what the reconciler knows about
  it right now. `:pending` = declared but not (yet) tracked — the start
  failed or hasn't been attempted; the next resync retries.
  """
  @type pod_status :: %{
          pod: Pod.t(),
          status: :pending | :starting | :running | :backing_off | :terminal,
          retries: non_neg_integer(),
          host_pid: pos_integer() | nil,
          last_exit: Tank.Events.last_exit() | nil,
          last_exit_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          restart_at: DateTime.t() | nil
        }

  @doc """
  The merged status of every declared pod, sorted by name. Live updates:
  subscribe to `Tank.Events`' `:pods` topic and re-read.
  """
  @spec status() :: [pod_status()]
  def status do
    observed = observed_status()

    list()
    |> Enum.map(&merge_status(&1, Map.get(observed, &1.name)))
    |> Enum.sort_by(& &1.pod.name)
  end

  @doc "The merged status of one pod. `{:error, :not_found}` if not declared."
  @spec status(String.t()) :: {:ok, pod_status()} | {:error, :not_found}
  def status(name) when is_binary(name) do
    with {:ok, pod} <- get(name) do
      {:ok, merge_status(pod, Map.get(observed_status(), name))}
    end
  end

  defp merge_status(pod, nil) do
    %{
      pod: pod,
      status: :pending,
      retries: 0,
      host_pid: nil,
      last_exit: nil,
      last_exit_at: nil,
      started_at: nil,
      restart_at: nil
    }
  end

  defp merge_status(pod, observed), do: Map.put(observed, :pod, pod)

  # The reconciler may be down (embedder without one, tests): everything is
  # then honestly :pending rather than an exit.
  defp observed_status do
    Reconciler.status()
  catch
    :exit, _ -> %{}
  end

  @doc """
  The last captured log entries for a pod, oldest first (`tail: 200` by
  default) — see `Tank.Logs` for the entry shape, live following via
  `Tank.Logs.subscribe/1`, and capture configuration.

      Tank.logs("web")
      Tank.logs("web", tail: 50)
  """
  @spec logs(String.t(), keyword()) :: {:ok, [Tank.Logs.entry()]}
  def logs(pod, opts \\ []), do: Tank.Logs.tail(pod, opts)

  @doc """
  Run an interactive command *inside* a running pod — `docker exec -it`.

  Resolves the pod's running workload, starts a **second** process that enters
  the container's namespaces (mount → its rootfs, pid → its procs, net/uts/ipc)
  with a PTY, and hands the caller's terminal to it. Typing `exit` ends only
  this exec session; the pod's main process keeps running. Exec again, or run
  several at once.

      Tank.exec("web", ["/bin/bash"])
      Tank.exec("web", ["/bin/sh", "-c", "ps aux"], cwd: "/tmp")

  `argv` is the command to run (its first element is the program). `opts`:

    * `:cwd` — working directory inside the container. Defaults to the
      container's `working_dir` (the image `WorkingDir`).
    * `:env` — extra environment as `["KEY=VAL", …]`, merged *over* the
      container's own environment. By default the exec session inherits the
      container's resolved env (image `Env` + the spec's), exactly like
      `docker exec` — so `PATH` resolves inside the rootfs — plus a default
      `TERM=xterm` when the container set none, for a usable shell.

  Returns the exec's terminal result — `{:ok, {:exited, code}}` /
  `{:ok, {:signaled, signum}}` — or `{:error, reason}` (`:not_running` when the
  pod has no live workload, or a `Linx.Process` / `Linx.Tty` setup error).

  > #### Runs in the caller's process {: .info}
  >
  > `exec/3` blocks the calling process for the life of the session and routes
  > the PTY through it, so call it straight from iex (or a process that owns a
  > terminal). It is deliberately *not* a cast into another process — the byte
  > pump must live where the terminal is.
  """
  @spec exec(String.t(), [String.t()], keyword()) ::
          {:ok, {:exited, non_neg_integer()} | {:signaled, pos_integer()} | :detached}
          | {:error, term()}
  def exec(pod_name, argv, opts \\ [])
      when is_binary(pod_name) and is_list(argv) and argv != [] do
    with {:ok, ctx} <- resolve_exec_context(pod_name),
         {:ok, session} <- Linx.Process.enter(ctx.host_pid, enter_opts(ctx, argv, opts)) do
      tty_attach(session)
    end
  end

  # Hand the caller's terminal to `session`, picking the mode that fits the
  # terminal. `:controlling` (a local tty) is preferred: it reads /dev/tty in
  # raw mode, so Ctrl-C reaches the *container's* foreground process as SIGINT
  # rather than tripping the BEAM's own break handler — and it gets real
  # SIGWINCH resize. Over SSH/`:remsh` there is no local tty, so `attach`
  # refuses with `:no_local_tty` and we fall back to the universal
  # `:group_leader` pump (which has its own ssh_cli-aware Ctrl-C handling).
  # Both modes honour the default Ctrl-P Ctrl-Q detach.
  defp tty_attach(session) do
    case Linx.Tty.attach(:controlling, session) do
      {:error, :no_local_tty} -> Linx.Tty.attach(:group_leader, session)
      result -> result
    end
  end

  # Resolve a pod name to its container's exec context (host pid + env + cwd)
  # via the reconciler's view of what's running and the owning Tank.Runtime.
  defp resolve_exec_context(pod_name) do
    case Map.fetch(Reconciler.running(), pod_name) do
      {:ok, runtime} -> Runtime.exec_context(runtime)
      :error -> {:error, :not_running}
    end
  end

  defp enter_opts(ctx, argv, opts) do
    [
      argv: argv,
      stdio: :pty,
      auto_proceed: true,
      cwd: Keyword.get(opts, :cwd, ctx.working_dir),
      env: exec_env(ctx.env, Keyword.get(opts, :env, []))
    ]
  end

  # The container's env, a default TERM when it set none (for a usable shell),
  # then the caller's :env overrides merged on top -- last writer per key wins.
  defp exec_env(container_env, overrides) do
    has_term? = Enum.any?(container_env, &String.starts_with?(&1, "TERM="))
    base = if has_term?, do: container_env, else: ["TERM=xterm" | container_env]
    merge_env(base, overrides)
  end

  defp merge_env(base, overrides) do
    over_keys = MapSet.new(overrides, &env_key/1)
    Enum.reject(base, &MapSet.member?(over_keys, env_key(&1))) ++ overrides
  end

  defp env_key(kv), do: kv |> String.split("=", parts: 2) |> hd()

  @doc """
  Attach to a `tty: true` pod's main process — `docker attach`.

  Where `exec/3` runs a *second* process inside the pod, `attach/1` takes over
  the pod's **main** process's terminal: the container *is* the interactive
  program (declare its container with `tty: true`). Because ending that program
  stops the container, leave without killing it by pressing the detach sequence
  — `Ctrl-P` `Ctrl-Q` — which returns `{:ok, :detached}` with the pod still
  running, ready to re-attach.

      Tank.apply(%{
        name: "console",
        containers: [%{name: "sh", image: "debian:13",
                       command: ["/bin/bash"], tty: true}]
      })

      Tank.attach("console")   #=> your terminal becomes the pod's bash

  Returns the session's terminal result — `{:ok, {:exited, code}}` /
  `{:ok, {:signaled, signum}}` (the program ended — the pod stops and the
  reconciler applies its restart policy), `{:ok, :detached}` (you detached), or
  `{:error, reason}` (`:not_running` if the pod has no live workload,
  `:not_a_tty` if its container wasn't declared `tty: true`).

  Like `exec/3`, this runs in and blocks the caller's process and routes the PTY
  through it — call it straight from `iex`.
  """
  @spec attach(String.t()) ::
          {:ok, {:exited, non_neg_integer()} | {:signaled, pos_integer()} | :detached}
          | {:error, term()}
  def attach(pod_name) when is_binary(pod_name) do
    case Map.fetch(Reconciler.running(), pod_name) do
      {:ok, runtime} -> attach_session(runtime)
      :error -> {:error, :not_running}
    end
  end

  defp attach_session(runtime) do
    with {:ok, session} <- Runtime.begin_attach(runtime, self()) do
      try do
        tty_attach(session)
      after
        Runtime.end_attach(runtime)
      end
    end
  end

  @doc false
  # Bootstrap seed: write each spec create-if-absent, so config never clobbers
  # runtime-changed state. Invalid specs and write failures are logged, not
  # raised -- a bad entry in the seed list shouldn't take down the node.
  @spec seed([spec()]) :: :ok
  def seed(specs) when is_list(specs) do
    Enum.each(specs, fn spec ->
      with {:ok, pod} <- to_pod(spec),
           result when result in [:ok, {:error, :exists}] <- Store.create_pod(pod) do
        :ok
      else
        {:error, reason} -> Logger.warning("Tank: skipping seed pod: #{inspect(reason)}")
      end
    end)
  end

  defp to_pod(%Pod{} = pod), do: {:ok, pod}
  defp to_pod(spec) when is_map(spec) or is_list(spec), do: Pod.new(spec)
  defp to_pod(other), do: {:error, {:invalid_pod_spec, other}}

  # Wake the reconciler so a write converges promptly. Best-effort: a no-op when
  # no reconciler is running (e.g. a consumer driving Tank.Runtime directly).
  defp nudge, do: Tank.Reconciler.nudge()
end
