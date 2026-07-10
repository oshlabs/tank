defmodule Tank.Console.Session do
  @moduledoc false

  # One console session: owns the Linx PTY session (exec: an entered process;
  # attach: the pod's main workload via Runtime.begin_attach) and relays
  # bytes to/from the consumer. See Tank.Console for the contract.

  use GenServer, restart: :temporary

  alias Linx.Process, as: Workload
  alias Tank.{Console, Runtime}

  # When the consumer's mailbox holds this many messages, output chunks are
  # dropped (a `cat /dev/urandom` must not balloon the BEAM); a marker is
  # emitted once the consumer drains.
  @consumer_lag_cap 500

  def start_link(spec), do: GenServer.start_link(__MODULE__, spec)

  @impl true
  def init({:exec, pod, argv, opts}) do
    Process.flag(:trap_exit, true)
    consumer = Keyword.fetch!(opts, :consumer)

    with {:ok, ctx} <- Console.resolve_exec_context(pod),
         {:ok, workload} <- Workload.enter(ctx.host_pid, Console.enter_opts(ctx, argv, opts)) do
      {:ok, ready(:exec, pod, workload, nil, consumer, opts)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:attach, pod, opts}) do
    Process.flag(:trap_exit, true)
    consumer = Keyword.fetch!(opts, :consumer)

    with {:ok, runtime} <- Console.resolve_runtime(pod),
         {:ok, workload} <- Runtime.begin_attach(runtime, self()) do
      {:ok, ready(:attach, pod, workload, runtime, consumer, opts)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp ready(mode, pod, workload, runtime, consumer, opts) do
    if cols = opts[:cols],
      do: Workload.pty_set_winsize(workload, {opts[:rows] || 24, cols, 0, 0})

    %{
      mode: mode,
      pod: pod,
      workload: workload,
      runtime: runtime,
      consumer: consumer,
      consumer_ref: Process.monitor(consumer),
      dropped: 0
    }
  end

  # === consumer-facing calls ================================================

  @impl true
  def handle_call({:write, bytes}, _from, state),
    do: {:reply, Workload.pty_write(state.workload, bytes), state}

  def handle_call({:resize, cols, rows}, _from, state),
    do: {:reply, Workload.pty_set_winsize(state.workload, {rows, cols, 0, 0}), state}

  def handle_call({:set_consumer, consumer}, _from, state) do
    Process.demonitor(state.consumer_ref, [:flush])
    {:reply, :ok, %{state | consumer: consumer, consumer_ref: Process.monitor(consumer)}}
  end

  # === the byte pump ========================================================

  @impl true
  def handle_info({:linx_process, :pty_out, bytes}, state) do
    # In attach mode, keep the pod's log whole: the runtime's own tee only
    # fires while the runtime owns the session, which it doesn't right now.
    if state.mode == :attach, do: Runtime.tee_pty(state.runtime, bytes)
    {:noreply, deliver(state, bytes)}
  end

  def handle_info({:linx_process, :exited, code}, state),
    do: finish(state, {:exit, {:exited, code}})

  def handle_info({:linx_process, :signaled, signum}, state),
    do: finish(state, {:exit, {:signaled, signum}})

  def handle_info({:linx_process, :error, errno, stage}, state),
    do: finish(state, {:exit, {:error, {errno, stage}}})

  def handle_info({:linx_process, _}, state), do: {:noreply, state}
  def handle_info({:linx_process, _, _}, state), do: {:noreply, state}

  # The consumer vanished: close — an exec's process is stopped by
  # terminate/2; an attached pod is merely detached.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{consumer_ref: ref} = state),
    do: {:stop, :normal, %{state | consumer: nil, consumer_ref: nil}}

  # The workload session crashed (it normally lingers post-exit).
  def handle_info({:EXIT, workload, reason}, %{workload: workload} = state),
    do: finish(state, {:exit, {:error, {:session_down, reason}}})

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # === teardown =============================================================

  @impl true
  def terminate(_reason, state) do
    case state.mode do
      :exec ->
        # Reap the entered process (same as Runtime does for workloads).
        if is_pid(state.workload) and Process.alive?(state.workload),
          do: GenServer.stop(state.workload, :normal)

      :attach ->
        # Detach: hand ownership back; the runtime re-derives the workload's
        # state (and acts on a death that happened on our watch).
        try do
          Runtime.end_attach(state.runtime)
        catch
          :exit, _ -> :ok
        end
    end

    notify(state, :closed)
    :ok
  end

  # A terminal event: tell the consumer what happened, then stop. terminate/2
  # still runs (trap_exit) — its :closed after an :exit is harmless.
  defp finish(state, exit_msg) do
    notify(state, exit_msg)
    {:stop, :normal, state}
  end

  defp deliver(%{consumer: consumer} = state, bytes) when is_pid(consumer) do
    lagging? =
      case Process.info(consumer, :message_queue_len) do
        {:message_queue_len, n} -> n > @consumer_lag_cap
        nil -> true
      end

    cond do
      lagging? ->
        %{state | dropped: state.dropped + byte_size(bytes)}

      state.dropped > 0 ->
        notify(
          state,
          {:data, "\r\n\e[2m[tank: #{state.dropped} bytes of output dropped]\e[0m\r\n"}
        )

        notify(state, {:data, bytes})
        %{state | dropped: 0}

      true ->
        notify(state, {:data, bytes})
        state
    end
  end

  defp deliver(state, _bytes), do: state

  defp notify(%{consumer: consumer}, msg) when is_pid(consumer),
    do: send(consumer, {:tank_console, self(), msg})

  defp notify(_state, _msg), do: :ok
end
