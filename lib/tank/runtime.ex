defmodule Tank.Runtime do
  @moduledoc """
  Brings one pod to running reality and supervises it.

  `start_link/2` takes a `%Tank.Pod{}` and, at the `Linx.Process` `:ready`
  checkpoint, runs the full host-side bring-up:

    1. pull the image and derive run params (`Tank.OCI`),
    2. spawn the workload into namespaces, parked at the checkpoint,
    3. build the rootfs (`Tank.Runtime.Rootfs`) with per-pod `/etc` files
       (`Tank.Runtime.Etc`),
    4. configure the network (`Tank.Runtime.Network`),
    5. apply cgroup limits (`Tank.Runtime.Limits`),
    6. `proceed` — the workload `execve`s inside its container.

  ## Scope (M4)

  One container per pod (sidecars are M7); the workload runs as the image's
  default user with **no** user namespace; container stdio goes to `/dev/null`
  (log capture is a later concern). A pod's netns may still hold several NICs.

  ## Owner events

  The `:owner` option receives:

    * `{:tank, :running, host_pid}` — configured and running.
    * `{:tank, :exited, code}` / `{:tank, :signaled, signum}` /
      `{:tank, :error, reason}` — terminal.

  The GenServer stops when its workload terminates (clean exit → `:normal`,
  otherwise abnormal), so a supervisor restarts the whole composite — a fresh
  rootfs and namespace built from scratch — per the pod's `:restart` policy.

  ## Options

    * `:owner` — pid for `{:tank, _}` events (default: none).
    * `:data_dir` — base dir for per-pod scratch (`<data_dir>/run/<pod>`);
      defaults to `:tank, :data_dir` or a tmp dir.
    * `:image` — keyword opts forwarded to `Tank.Image.pull/2` (e.g. `:cache`).
  """

  use GenServer
  require Logger

  alias Linx.Process, as: Workload
  alias Tank.{Container, OCI, Pod}
  alias Tank.Runtime.{Etc, Limits, Network, Rootfs}

  # Always-fresh namespaces; :net is added unless the pod shares the host's.
  @base_namespaces [:mount, :pid, :uts, :ipc]

  # === API ==================================================================

  @doc "Supervisor child spec; restart type derived from the pod's :restart policy."
  def child_spec({%Pod{} = pod, opts}) do
    %{
      id: {__MODULE__, pod.name},
      start: {__MODULE__, :start_link, [pod, opts]},
      restart: restart_type(pod.restart),
      type: :worker
    }
  end

  def child_spec(%Pod{} = pod), do: child_spec({pod, []})

  defp restart_type(:always), do: :permanent
  defp restart_type(:on_failure), do: :transient
  defp restart_type(:never), do: :temporary

  @doc "Start and bring up one pod. See the moduledoc for options."
  @spec start_link(Pod.t(), keyword()) :: GenServer.on_start()
  def start_link(%Pod{} = pod, opts \\ []), do: GenServer.start_link(__MODULE__, {pod, opts})

  @doc "The workload's host pid, once `:running`. `{:error, :not_running}` before then."
  @spec host_pid(pid()) :: {:ok, pos_integer()} | {:error, :not_running}
  def host_pid(runtime), do: GenServer.call(runtime, :host_pid)

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
          etc_files: []
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

    with {:ok, rootfs, config} <- resolve_image(state.container, state.image_opts),
         {:ok, run} <- OCI.run_params(state.container, config),
         etc_files = Etc.materialize(state.pod, scratch),
         {:ok, session} <- spawn_workload(state.pod, run) do
      {:noreply,
       %{state | session: session, rootfs: rootfs, scratch: scratch, etc_files: etc_files}}
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

  defp spawn_workload(%Pod{} = pod, run) do
    Workload.spawn(
      argv: run.argv,
      env: run.env,
      cwd: run.cwd,
      namespaces: namespaces(pod.network),
      owner: self(),
      stdio: :devnull
    )
  end

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

  # The workload session is linked; with trap_exit on, its unexpected death
  # arrives here (it normally lingers post-exit, so this means it crashed).
  def handle_info({:EXIT, session, reason}, %{session: session} = state) do
    notify(state, {:tank, :error, {:session_down, reason}})
    {:stop, {:session_down, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Lifecycle chatter we don't act on (PTY output, etc.).
  def handle_info({:linx_process, _}, state), do: {:noreply, state}
  def handle_info({:linx_process, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Runs in the child's namespaces, host-side, while the workload waits.
  defp bring_up(state, host_pid) do
    with :ok <- Rootfs.setup(host_pid, state.rootfs, state.etc_files),
         :ok <- Network.setup(host_pid, state.pod.network),
         {:ok, cgroup} <- Limits.apply(state.pod.name, host_pid, state.container.limits) do
      {:ok, cgroup}
    end
  end

  @impl true
  def handle_call(:host_pid, _from, %{host_pid: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:host_pid, _from, %{host_pid: pid} = state),
    do: {:reply, {:ok, pid}, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and Process.alive?(state.session),
      do: GenServer.stop(state.session, :normal)

    Limits.remove(state.cgroup)
    if state.scratch, do: File.rm_rf(state.scratch)
    :ok
  end

  # === helpers ==============================================================

  defp notify(%{owner: nil}, _msg), do: :ok
  defp notify(%{owner: owner}, msg), do: send(owner, msg)

  defp default_data_dir do
    Application.get_env(:tank, :data_dir) || Path.join(System.tmp_dir!(), "tank")
  end
end
