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
end
