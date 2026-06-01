defmodule Tank.RuntimeTest do
  # Pulls a real image and brings up a real container (rootfs + netns + cgroup):
  # needs root. Run via ./sudotest.sh.
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.{Pod, Runtime}

  @cache Path.join(System.tmp_dir!(), "tank-image-cache")

  setup_all do
    # Warm the image cache so per-test bring-up is fast.
    {:ok, _} = Tank.Image.pull("alpine:latest", cache: @cache)
    :ok
  end

  defp pod(name, container_attrs, pod_attrs \\ %{}) do
    container = Map.merge(%{name: "app", image: "alpine:latest"}, container_attrs)

    Pod.new!(Map.merge(%{name: name, network: :none, containers: [container]}, pod_attrs))
  end

  test "brings a pod to running with its rootfs, network, and cgroup limits" do
    p =
      pod("rt-run", %{
        command: ["/bin/sleep", "30"],
        limits: %{memory: 64 <<< 20, pids: 50}
      })

    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: [cache: @cache])

    assert_receive {:tank, :running, host_pid}, 15_000
    assert {:ok, ^host_pid} = Runtime.host_pid(runtime)

    # The cgroup carries the memory limit, and holds the workload.
    cgroup = "/sys/fs/cgroup/tank/rt-run"
    assert File.read!(Path.join(cgroup, "memory.max")) |> String.trim() == "67108864"
    assert File.read!(Path.join(cgroup, "pids.max")) |> String.trim() == "50"
    procs = File.read!(Path.join(cgroup, "cgroup.procs")) |> String.split()
    assert Integer.to_string(host_pid) in procs

    # Clean shutdown tears the cgroup down.
    GenServer.stop(runtime)
    refute File.dir?(cgroup)
  end

  test "a pod with no limits needs no cgroup" do
    p = pod("rt-nolimits", %{command: ["/bin/sleep", "10"]})
    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: [cache: @cache])

    assert_receive {:tank, :running, _host_pid}, 15_000
    refute File.dir?("/sys/fs/cgroup/tank/rt-nolimits")

    GenServer.stop(runtime)
  end

  test "the supervisor restarts the composite on workload death (restart: :on_failure)" do
    {:ok, sup} = start_supervised({DynamicSupervisor, strategy: :one_for_one, max_restarts: 5})

    # owner: self() is stable across restarts (the child spec is re-run with the
    # same opts), so each fresh composite reports its :running back to us.
    p = pod("rt-restart", %{command: ["/bin/sleep", "60"]}, %{restart: :on_failure})
    {:ok, _} = DynamicSupervisor.start_child(sup, {Runtime, {p, [owner: self()]}})

    assert_receive {:tank, :running, host_pid1}, 15_000

    # Kill the workload out of band; the composite dies and is restarted fresh.
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(host_pid1)])

    assert_receive {:tank, :running, host_pid2}, 15_000
    assert host_pid2 != host_pid1
  end

  describe "attach handoff (tty: true)" do
    test "begin_attach hands off the main PTY; detach leaves the workload running" do
      # /bin/cat as the main process: interactive, stays alive on a PTY.
      p = pod("rt-attach", %{command: ["/bin/cat"], tty: true})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: [cache: @cache])
      assert_receive {:tank, :running, _host_pid}, 15_000

      # Hand the session to this test; we become the owner of :pty_out.
      {:ok, session} = Runtime.begin_attach(runtime, self())
      :ok = Linx.Process.pty_write(session, "hello\n")
      assert_receive {:linx_process, :pty_out, bytes}, 5_000
      assert bytes =~ "hello"

      # Detach (no exit): ownership returns to the runtime, which stays up.
      :ok = Runtime.end_attach(runtime)
      assert Process.alive?(runtime)
      assert {:ok, %{stage: :running}} = Linx.Process.info(session)

      GenServer.stop(runtime)
    end

    test "a main process that exits during attach makes end_attach stop the runtime" do
      p = pod("rt-attach-exit", %{command: ["/bin/cat"], tty: true}, %{restart: :never})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: [cache: @cache])
      assert_receive {:tank, :running, _host_pid}, 15_000

      # The runtime stops abnormally below; trap its linked exit so it doesn't
      # take the test process down with it.
      Process.flag(:trap_exit, true)

      {:ok, session} = Runtime.begin_attach(runtime, self())
      ref = Process.monitor(runtime)

      # The main process dies while we (not the runtime) own the session. It is
      # PID 1 in its namespace, so only SIGKILL is honoured (the kernel drops an
      # un-handled SIGTERM to a namespace init).
      :ok = Linx.Process.signal(session, 9)
      assert_receive {:linx_process, :signaled, 9}, 5_000

      # end_attach re-derives the terminal state and stops the runtime — so in
      # production the reconciler would apply the restart policy.
      :ok = Runtime.end_attach(runtime)
      assert_receive {:DOWN, ^ref, :process, ^runtime, _}, 5_000
      assert_received {:tank, :signaled, 9}
    end

    test "begin_attach refuses a non-tty container with :not_a_tty" do
      p = pod("rt-attach-notty", %{command: ["/bin/sleep", "30"]})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: [cache: @cache])
      assert_receive {:tank, :running, _host_pid}, 15_000

      assert {:error, :not_a_tty} = Runtime.begin_attach(runtime, self())

      GenServer.stop(runtime)
    end
  end
end
