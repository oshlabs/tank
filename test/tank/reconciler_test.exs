defmodule Tank.ReconcilerTest do
  # Drives the reconcile loop against a real store, but with a stub runtime
  # (no containers), so it needs no root.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Tank.Reconciler

  # A stand-in for Tank.Runtime: a process that just stays alive, so the
  # reconciler can start/stop/monitor it without bringing up a container.
  defmodule StubRuntime do
    use GenServer

    def child_spec({pod, _opts}),
      do: %{id: {__MODULE__, pod.name}, start: {__MODULE__, :start_link, [pod]}}

    def start_link(pod), do: GenServer.start_link(__MODULE__, pod)

    @impl true
    def init(pod), do: {:ok, pod}
  end

  setup_all do
    dir =
      Path.join(System.tmp_dir!(), "tank-reconciler-test-#{System.unique_integer([:positive])}")

    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)
    pid = start_supervised!({Reconciler, runtime: StubRuntime, interval: :timer.hours(1)})
    {:ok, reconciler: pid}
  end

  defp pod(name, attrs \\ %{}) do
    Map.merge(%{name: name, containers: [%{name: "c", image: "alpine"}]}, attrs)
  end

  test "starts a pod that was applied", %{reconciler: r} do
    :ok = Tank.apply(pod("web"))
    :ok = Reconciler.sync(r)

    assert %{"web" => pid} = Reconciler.running(r)
    assert Process.alive?(pid)
  end

  test "stops a pod that was deleted", %{reconciler: r} do
    :ok = Tank.apply(pod("web"))
    :ok = Reconciler.sync(r)
    %{"web" => pid} = Reconciler.running(r)

    :ok = Tank.delete("web")
    :ok = Reconciler.sync(r)

    assert Reconciler.running(r) == %{}
    refute Process.alive?(pid)
  end

  test "restarts a pod whose spec changed", %{reconciler: r} do
    :ok = Tank.apply(pod("web", %{restart: :always}))
    :ok = Reconciler.sync(r)
    %{"web" => pid1} = Reconciler.running(r)

    :ok = Tank.apply(pod("web", %{restart: :never}))
    :ok = Reconciler.sync(r)
    %{"web" => pid2} = Reconciler.running(r)

    assert pid2 != pid1
    refute Process.alive?(pid1)
    assert Process.alive?(pid2)
  end

  test "leaves an unchanged pod running across passes", %{reconciler: r} do
    :ok = Tank.apply(pod("web"))
    :ok = Reconciler.sync(r)
    %{"web" => pid} = Reconciler.running(r)

    :ok = Reconciler.sync(r)
    assert %{"web" => ^pid} = Reconciler.running(r)
  end

  test "converges many pods at once", %{reconciler: r} do
    for n <- 1..5, do: :ok = Tank.apply(pod("p#{n}"))
    :ok = Reconciler.sync(r)

    assert Reconciler.running(r) |> Map.keys() |> Enum.sort() == ~w(p1 p2 p3 p4 p5)
  end

  test "restarts a crashed pod on the next resync", %{reconciler: r} do
    :ok = Tank.apply(pod("web"))
    :ok = Reconciler.sync(r)
    %{"web" => pid1} = Reconciler.running(r)

    # Simulate a crash; the reconciler's monitor drops it.
    Process.exit(pid1, :kill)
    # Give the DOWN time to be processed before the next pass.
    Process.sleep(50)

    :ok = Reconciler.sync(r)
    %{"web" => pid2} = Reconciler.running(r)
    assert pid2 != pid1
    assert Process.alive?(pid2)
  end
end
