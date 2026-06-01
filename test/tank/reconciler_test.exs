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
    # Small backoff so crash-recovery is observable; a long interval so resync
    # never interferes with the backoff path under test.
    # A distinct name so Tank.apply/delete's nudge to the default Tank.Reconciler
    # doesn't reach this one -- these tests drive it deterministically via sync/1.
    pid =
      start_supervised!(
        {Reconciler,
         name: :reconciler_under_test,
         runtime: StubRuntime,
         interval: :timer.hours(1),
         backoff_base: 20,
         backoff_cap: 200,
         stable_window: :timer.seconds(30)}
      )

    {:ok, reconciler: pid}
  end

  defp pod(name, attrs \\ %{}) do
    Map.merge(%{name: name, containers: [%{name: "c", image: "alpine"}]}, attrs)
  end

  # Poll until `fun` returns a truthy value, or fail after `timeout` ms.
  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(5) && false) end)
    |> Enum.find(fn result -> result || System.monotonic_time(:millisecond) > deadline end)
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

  test "restarts a crashed pod automatically (restart: :always)", %{reconciler: r} do
    :ok = Tank.apply(pod("web", %{restart: :always}))
    :ok = Reconciler.sync(r)
    %{"web" => pid1} = Reconciler.running(r)

    Process.exit(pid1, :kill)

    # Restarted by the backoff path, with no resync.
    assert eventually(fn ->
             case Reconciler.running(r) do
               %{"web" => pid2} when pid2 != pid1 -> Process.alive?(pid2)
               _ -> false
             end
           end)
  end

  test "restart: :always also restarts after a clean exit", %{reconciler: r} do
    :ok = Tank.apply(pod("web", %{restart: :always}))
    :ok = Reconciler.sync(r)
    %{"web" => pid1} = Reconciler.running(r)

    GenServer.stop(pid1, :normal)

    assert eventually(fn ->
             match?(%{"web" => pid2} when pid2 != pid1, Reconciler.running(r))
           end)
  end

  test "restart: :on_failure restarts a crash but not a clean exit", %{reconciler: r} do
    # crash -> restart
    :ok = Tank.apply(pod("crashy", %{restart: :on_failure}))
    :ok = Reconciler.sync(r)
    %{"crashy" => pid} = Reconciler.running(r)
    Process.exit(pid, :kill)

    assert eventually(fn ->
             match?(%{"crashy" => _}, Reconciler.running(r)) and
               Reconciler.running(r)["crashy"] != pid
           end)

    # clean exit -> terminal
    :ok = Tank.apply(pod("clean", %{restart: :on_failure}))
    :ok = Reconciler.sync(r)
    %{"clean" => clean_pid} = Reconciler.running(r)
    GenServer.stop(clean_pid, :normal)

    assert eventually(fn -> Reconciler.status(r)["clean"][:status] == :terminal end)
    refute Map.has_key?(Reconciler.running(r), "clean")
  end

  test "restart: :never never restarts and goes terminal", %{reconciler: r} do
    :ok = Tank.apply(pod("once", %{restart: :never}))
    :ok = Reconciler.sync(r)
    %{"once" => pid} = Reconciler.running(r)

    Process.exit(pid, :kill)

    assert eventually(fn -> Reconciler.status(r)["once"][:status] == :terminal end)
    # A resync does not resurrect a terminal pod.
    :ok = Reconciler.sync(r)
    assert Reconciler.status(r)["once"][:status] == :terminal
    assert Reconciler.running(r) == %{}
  end

  test "backoff grows with consecutive crashes", %{reconciler: r} do
    :ok = Tank.apply(pod("loop", %{restart: :always}))
    :ok = Reconciler.sync(r)

    # Crash a few times in quick succession; the retry count climbs.
    retries =
      for _ <- 1..3 do
        %{"loop" => pid} = wait_running(r)
        Process.exit(pid, :kill)
        eventually(fn -> Reconciler.status(r)["loop"][:status] == :backing_off end)
        Reconciler.status(r)["loop"][:retries]
      end

    assert retries == [1, 2, 3]
  end

  defp wait_running(r) do
    eventually(fn -> match?(%{"loop" => _}, Reconciler.running(r)) && Reconciler.running(r) end)
  end
end
