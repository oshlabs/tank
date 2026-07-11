defmodule Tank.Runtime do
  @moduledoc """
  Brings one pod to running reality and supervises it.

  `start_link/2` takes a `%Tank.Pod{}` and, at the `Linx.Process` `:ready`
  checkpoint, runs the full host-side bring-up:

    1. pull the image and derive run params (`Tank.OCI`),
    2. spawn the workload into namespaces, parked at the checkpoint,
    3. build the rootfs (`Tank.Runtime.Rootfs`) with per-pod `/etc` files,
    4. configure the network (`Tank.Runtime.Network`),
    5. apply cgroup limits,
    6. `proceed` — the workload `execve`s inside its container.

  ## Scope (M4)

  One container per pod (sidecars are M7); the workload runs as the image's
  default user with **no** user namespace. Container stdio is captured: a
  per-pod `Tank.Runtime.Logs` collector receives stdout/stderr over
  `{:connect_unix, _}` stdio (or the PTY tee for `tty: true`) and writes
  timestamped, stream-tagged lines under `<log_dir>/<pod>/` — see
  `Tank.Logs` for the read API and configuration (`config :tank, :logs,
  enabled: false` restores the old stdio → `/dev/null`). A pod's netns may
  still hold several NICs.

  ## Owner events

  The `:owner` option receives `{:tank, pod_name, event}` — name-attributed
  so one owner (the reconciler) can watch every runtime:

    * `{:tank, name, {:running, host_pid}}` — configured and running.
    * `{:tank, name, {:exited, code}}` / `{:tank, name, {:signaled, signum}}`
      / `{:tank, name, {:error, reason}}` — terminal.

  The GenServer stops when its workload terminates: a clean exit → `:normal`, a
  non-zero exit or signal → `{:shutdown, {:workload_exited | :workload_signaled,
  …}}` (an expected outcome, so OTP logs no crash report), and a genuine setup
  or session failure → an abnormal reason. The reconciler reads the reason and
  rebuilds the whole composite — a fresh rootfs and namespace — per the pod's
  `:restart` policy.

  ## Options

    * `:owner` — pid for `{:tank, _}` events (default: none).
    * `:data_dir` — base dir for per-pod scratch (`<data_dir>/run/<pod>`);
      defaults to `:tank, :data_dir` or a tmp dir.
    * `:image` — keyword opts forwarded to `Tank.Image.pull/2` (e.g. `:cache`).
  """

  use GenServer
  require Logger

  alias Linx.Process, as: Workload
  alias Tank.{Container, Net, OCI, Pod}
  alias Tank.Runtime.{Etc, Limits, Logs, Network, Rootfs, Volumes}

  # Always-fresh namespaces; :net is added unless the pod shares the host's.
  @base_namespaces [:mount, :pid, :uts, :ipc]

  # === API ==================================================================

  @doc """
  Supervisor child spec. `restart: :temporary` — OTP never restarts a runtime;
  `Tank.Reconciler` owns restart (it monitors the runtime and acts on the stop
  reason per the pod's `:restart` policy). Pod policy lives in the reconciler,
  not the child spec.
  """
  def child_spec({%Pod{} = pod, opts}) do
    %{
      id: {__MODULE__, pod.name},
      start: {__MODULE__, :start_link, [pod, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def child_spec(%Pod{} = pod), do: child_spec({pod, []})

  @doc "Start and bring up one pod. See the moduledoc for options."
  @spec start_link(Pod.t(), keyword()) :: GenServer.on_start()
  def start_link(%Pod{} = pod, opts \\ []), do: GenServer.start_link(__MODULE__, {pod, opts})

  @doc "The workload's host pid, once `:running`. `{:error, :not_running}` before then."
  @spec host_pid(pid()) :: {:ok, pos_integer()} | {:error, :not_running}
  def host_pid(runtime), do: GenServer.call(runtime, :host_pid)

  @typedoc """
  What `Tank.exec/3` needs to enter the container: the workload's host pid plus
  the container's resolved `env` (image `Env` merged with the spec's) and
  `working_dir` — so an exec session inherits the *container's* environment, not
  the host's.
  """
  @type exec_context :: %{host_pid: pos_integer(), env: [String.t()], working_dir: String.t()}

  @doc "The container's exec context, once `:running`. `{:error, :not_running}` before then."
  @spec exec_context(pid()) :: {:ok, exec_context()} | {:error, :not_running}
  def exec_context(runtime), do: GenServer.call(runtime, :exec_context)

  @doc """
  Begin an attach to a `tty: true` container's main process: hand the session's
  event stream to `attacher` and return the session pid for `Linx.Tty.attach/3`.

  `{:error, :not_running}` if the workload isn't up yet; `{:error, :not_a_tty}`
  if the container wasn't started with `tty: true` (there is no PTY to attach
  to); `{:error, :attached}` if another attacher already holds the session.
  Pair every success with `end_attach/1` (the attacher is also monitored — a
  vanished attacher auto-detaches).
  """
  @spec begin_attach(pid(), pid()) ::
          {:ok, pid()} | {:error, :not_running | :not_a_tty | :attached}
  def begin_attach(runtime, attacher), do: GenServer.call(runtime, {:begin_attach, attacher})

  @doc """
  End an attach: take ownership of the session back and re-derive the workload's
  state. If it terminated while detached, the runtime acts on it now (stopping
  so the reconciler applies the restart policy). Best-effort — a no-op if the
  runtime is already gone.
  """
  @spec end_attach(pid()) :: :ok
  def end_attach(runtime) do
    GenServer.call(runtime, :end_attach)
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Feed PTY bytes into this runtime's log collector — used by
  # Tank.Console.Session during a web attach, when the console (not the
  # runtime) owns the session and the runtime's own :pty_out tee is silent.
  @spec tee_pty(pid(), binary()) :: :ok
  def tee_pty(runtime, bytes), do: GenServer.cast(runtime, {:tee_pty, bytes})

  # === lifecycle ============================================================

  @impl true
  def init({%Pod{} = pod, opts}) do
    # Trap exits so terminate/2 runs on a supervisor :shutdown (the reconciler
    # stops us via terminate_child) -- that's where we reap the workload and
    # tear down the cgroup/scratch.
    Process.flag(:trap_exit, true)

    case sole_container(pod) do
      {:ok, container} ->
        state = %{
          pod: pod,
          container: container,
          owner: opts[:owner],
          image_opts: Keyword.get(opts, :image, []),
          data_dir: Keyword.get(opts, :data_dir, default_data_dir()),
          session: nil,
          host_pid: nil,
          cgroup: nil,
          scratch: nil,
          rootfs: nil,
          etc_files: [],
          # Resolved at bring-up: container mounts as host-source bind specs.
          volume_mounts: [],
          # The pod's network with {:ipam, _} intents resolved (at bring-up).
          network: nil,
          # The per-pod log collector (Tank.Runtime.Logs); nil when disabled.
          logs: nil,
          # The current attacher (begin_attach/2), monitored; nil = unattached.
          attacher: nil,
          attacher_ref: nil,
          # The container's resolved run env/cwd, stashed for Tank.exec.
          env: [],
          working_dir: "/"
        }

        {:ok, state, {:continue, :bring_up}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # M4: one container per pod.
  defp sole_container(%Pod{containers: [container]}), do: {:ok, container}

  defp sole_container(%Pod{containers: [container | _], name: name}) do
    Logger.warning(
      "Tank.Runtime[#{name}]: multi-container pods are M7; running only #{container.name}"
    )

    {:ok, container}
  end

  defp sole_container(%Pod{}), do: {:error, :no_containers}

  @impl true
  def handle_continue(:bring_up, state) do
    scratch = Path.join([state.data_dir, "run", state.pod.name])

    # {:ipam, subnet} NIC intents resolve here, before /etc materialization,
    # so resolv.conf can carry the pool's DNS; a restarting pod re-allocates
    # (lease affinity keeps its address). The resolved network is what
    # Network.setup later actuates.
    with {:ok, rootfs, config} <- resolve_image(state.container, state.image_opts),
         {:ok, run} <- OCI.run_params(state.container, config),
         {:ok, network} <- Net.resolve(state.pod),
         {:ok, volume_mounts} <- Volumes.resolve(state.pod, state.container, state.data_dir),
         etc_files = Etc.materialize(%{state.pod | network: network}, scratch),
         # The collector's listeners must exist before the workload spawns:
         # linx connects the {:connect_unix, _} stdio host-side at spawn time.
         {:ok, logs} <-
           Logs.maybe_start(state.pod.name, state.container.name, scratch, state.data_dir),
         {:ok, session} <- spawn_workload(state.pod, state.container, run, logs) do
      {:noreply,
       %{
         state
         | session: session,
           rootfs: rootfs,
           scratch: scratch,
           etc_files: etc_files,
           volume_mounts: volume_mounts,
           network: network,
           logs: logs,
           env: run.env,
           working_dir: run.cwd
       }}
    else
      {:error, reason} -> {:stop, {:bring_up_failed, reason}, state}
    end
  end

  defp resolve_image(%Container{image: {:rootfs, path}}, _opts), do: {:ok, path, %{}}

  defp resolve_image(%Container{image: ref}, opts) when is_binary(ref) do
    case Tank.Image.pull(ref, opts) do
      {:ok, %{rootfs: rootfs, config: config}} -> {:ok, rootfs, config}
      {:error, _} = err -> err
    end
  end

  defp spawn_workload(%Pod{} = pod, %Container{} = container, run, logs) do
    Workload.spawn(
      argv: run.argv,
      env: tty_env(run.env, container.tty),
      cwd: run.cwd,
      namespaces: namespaces(pod.network),
      owner: self(),
      stdio: stdio(container, logs)
    )
  end

  # A `tty: true` container's main process runs on a PTY so Tank.attach can
  # take it over (its output reaches the log via the :pty_out tee below).
  # Otherwise stdout/stderr go to the collector's AF_UNIX listeners — linx
  # connects them host-side at spawn time — and stdin to /dev/null. With
  # capture disabled, all stdio is discarded as before.
  defp stdio(%Container{tty: true}, _logs), do: :pty
  defp stdio(%Container{}, nil), do: :devnull
  defp stdio(%Container{}, logs), do: Logs.stdio(logs)

  # A `tty: true` container's main process is interactive, so give it a default
  # `TERM` (unless the image set one) — without it readline features like Ctrl-L
  # don't work. Mirrors what `Tank.exec` does for exec sessions.
  defp tty_env(env, true) do
    if Enum.any?(env, &String.starts_with?(&1, "TERM=")), do: env, else: ["TERM=xterm" | env]
  end

  defp tty_env(env, false), do: env

  defp namespaces(:host), do: @base_namespaces
  defp namespaces(_network), do: [:net | @base_namespaces]

  # === the checkpoint =======================================================

  @impl true
  def handle_info({:linx_process, :ready, host_pid}, state) do
    case bring_up(state, host_pid) do
      {:ok, cgroup} ->
        :ok = Workload.proceed(state.session)
        {:noreply, %{state | host_pid: host_pid, cgroup: cgroup}}

      {:error, reason} ->
        Logger.error("Tank.Runtime[#{state.pod.name}]: bring-up failed: #{inspect(reason)}")
        Workload.abort(state.session)
        {:stop, {:bring_up_failed, reason}, state}
    end
  end

  def handle_info({:linx_process, :running}, state) do
    notify(state, {:running, state.host_pid})
    {:noreply, state}
  end

  def handle_info({:linx_process, :exited, 0}, state) do
    notify(state, {:exited, 0})
    {:stop, :normal, state}
  end

  # A non-zero exit / a signal is an expected workload outcome, not a Runtime
  # crash — stop under a `:shutdown` reason so OTP doesn't log a crash report.
  # The reconciler still sees a non-`:normal` reason and restarts per policy.
  def handle_info({:linx_process, :exited, code}, state) do
    notify(state, {:exited, code})
    {:stop, {:shutdown, {:workload_exited, code}}, state}
  end

  def handle_info({:linx_process, :signaled, signum}, state) do
    notify(state, {:signaled, signum})
    {:stop, {:shutdown, {:workload_signaled, signum}}, state}
  end

  def handle_info({:linx_process, :error, errno, stage}, state) do
    notify(state, {:error, {errno, stage}})
    {:stop, {:workload_error, errno, stage}, state}
  end

  # The attacher vanished without end_attach (a died LiveView/console):
  # auto-detach — reclaim ownership and re-derive, exactly like end_attach.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{attacher_ref: ref} = state) do
    state = clear_attacher(state)

    if is_pid(state.session) do
      case reclaim(state) do
        {:ok, state} -> {:noreply, state}
        {:stop, reason, state} -> {:stop, reason, state}
      end
    else
      {:noreply, state}
    end
  end

  # The workload session is linked; with trap_exit on, its unexpected death
  # arrives here (it normally lingers post-exit, so this means it crashed).
  def handle_info({:EXIT, session, reason}, %{session: session} = state) do
    notify(state, {:error, {:session_down, reason}})
    {:stop, {:session_down, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A tty container's merged PTY output, teed into the log. Only flows here
  # while the runtime owns the session — during an attach the attacher owns
  # it, so interactive bytes bypass the log (documented in Tank.Logs).
  def handle_info({:linx_process, :pty_out, bytes}, %{logs: logs} = state)
      when is_pid(logs) do
    Logs.pty_out(logs, bytes)
    {:noreply, state}
  end

  # Lifecycle chatter we don't act on.
  def handle_info({:linx_process, _}, state), do: {:noreply, state}
  def handle_info({:linx_process, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Runs in the child's namespaces, host-side, while the workload waits. The
  # network was already resolved (intents → concrete addresses) at bring-up.
  defp bring_up(state, host_pid) do
    with :ok <- Rootfs.setup(host_pid, state.rootfs, state.etc_files, state.volume_mounts),
         :ok <- Network.setup(host_pid, state.network),
         {:ok, cgroup} <- Limits.apply(state.pod.name, host_pid, state.container.limits) do
      set_hostname(state.pod.name, host_pid)
      {:ok, cgroup}
    end
  end

  # The pod's UTS hostname is its name — that's what the fresh :uts namespace
  # is for, and what the DNS layer already assumes. kernel.hostname is a
  # sysctl, so Linx's per-namespace writer sets it from the host; without
  # this, pods keep whatever hostname the image baked in (debian images ship
  # "debuerreotype", the tool that built them). Soft-fail: a denied write
  # (exotic LSM) shouldn't stop a pod over a cosmetic name.
  defp set_hostname(name, host_pid) do
    case Linx.Sysctl.write("kernel/hostname", name, in: {:pid, host_pid}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Tank.Runtime[#{name}]: could not set hostname: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def handle_call(:host_pid, _from, %{host_pid: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:host_pid, _from, %{host_pid: pid} = state),
    do: {:reply, {:ok, pid}, state}

  def handle_call(:exec_context, _from, %{host_pid: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:exec_context, _from, %{host_pid: pid} = state),
    do:
      {:reply,
       {:ok,
        %{host_pid: pid, env: state.env, working_dir: state.working_dir, cgroup: state.cgroup}},
       state}

  def handle_call({:begin_attach, _attacher}, _from, %{attacher: current} = state)
      when is_pid(current) do
    {:reply, {:error, :attached}, state}
  end

  def handle_call({:begin_attach, attacher}, _from, %{session: session, host_pid: pid} = state)
      when is_pid(session) and is_integer(pid) do
    case Workload.pty_master(session) do
      {:ok, _} ->
        :ok = Workload.set_owner(session, attacher)

        {:reply, {:ok, session},
         %{state | attacher: attacher, attacher_ref: Process.monitor(attacher)}}

      {:error, :no_pty} ->
        {:reply, {:error, :not_a_tty}, state}
    end
  end

  def handle_call({:begin_attach, _attacher}, _from, state),
    do: {:reply, {:error, :not_running}, state}

  # Reclaim ownership and re-derive the workload's state (Model A, level-
  # triggered): if it terminated while detached, the owning runtime never saw
  # the lifecycle message, so we act on it now exactly as the handle_info
  # clauses would.
  def handle_call(:end_attach, _from, %{session: session} = state) when is_pid(session) do
    state = clear_attacher(state)

    case reclaim(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:stop, reason, state} -> {:stop, reason, :ok, state}
    end
  end

  def handle_call(:end_attach, _from, state), do: {:reply, :ok, clear_attacher(state)}

  # Console attach tees the bytes it owns back into the pod's log.
  @impl true
  def handle_cast({:tee_pty, bytes}, state) do
    if is_pid(state.logs), do: Logs.pty_out(state.logs, bytes)
    {:noreply, state}
  end

  # Take ownership of the session back and re-derive the workload's state: if
  # it terminated while attached, the runtime never saw the lifecycle message,
  # so it acts on it now exactly as the handle_info clauses would.
  defp reclaim(%{session: session} = state) do
    :ok = Workload.set_owner(session, self())

    case Workload.info(session) do
      {:ok, %{stage: stage, result: result}}
      when stage in [:exited, :signaled, :errored, :aborted] ->
        reclaim_terminal(result, state)

      _ ->
        {:ok, state}
    end
  end

  defp clear_attacher(%{attacher_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | attacher: nil, attacher_ref: nil}
  end

  defp reclaim_terminal({:exited, 0}, state) do
    notify(state, {:exited, 0})
    {:stop, :normal, state}
  end

  defp reclaim_terminal({:exited, code}, state) do
    notify(state, {:exited, code})
    {:stop, {:shutdown, {:workload_exited, code}}, state}
  end

  defp reclaim_terminal({:signaled, signum}, state) do
    notify(state, {:signaled, signum})
    {:stop, {:shutdown, {:workload_signaled, signum}}, state}
  end

  defp reclaim_terminal(other, state) do
    notify(state, {:error, other})
    {:stop, {:workload_terminated, other}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and Process.alive?(state.session),
      do: GenServer.stop(state.session, :normal)

    # After the workload: the collector drains what the workload wrote last,
    # then its scratch-dir sockets can be wiped with the scratch below.
    Logs.stop(state.logs)

    Limits.remove(state.cgroup)
    if state.scratch, do: File.rm_rf(state.scratch)
    :ok
  end

  # === helpers ==============================================================

  defp notify(%{owner: nil}, _event), do: :ok

  defp notify(%{owner: owner, pod: %{name: name}}, event),
    do: send(owner, {:tank, name, event})

  defp default_data_dir do
    Application.get_env(:tank, :data_dir) || Path.join(System.tmp_dir!(), "tank")
  end
end
