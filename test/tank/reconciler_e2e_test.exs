defmodule Tank.ReconcilerE2ETest do
  # The whole declarative loop against reality: Tank.apply -> the reconciler
  # brings up a real container; Tank.delete -> it's gone. Needs root.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.Reconciler

  @cache Path.join(System.tmp_dir!(), "tank-image-cache")

  setup_all do
    {:ok, _} = Tank.Image.pull("alpine:latest", cache: @cache)
    dir = Path.join(System.tmp_dir!(), "tank-e2e-test-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)

    # The real Tank.Runtime, owner: self() so we see :running; image cache via
    # runtime_opts. Long interval -- we drive passes with sync/1.
    r =
      start_supervised!(
        {Reconciler,
         runtime: Tank.Runtime,
         owner: self(),
         runtime_opts: [image: [cache: @cache]],
         interval: :timer.hours(1)}
      )

    {:ok, reconciler: r}
  end

  test "apply brings up a real container; delete tears it down", %{reconciler: r} do
    :ok =
      Tank.apply(%{
        name: "e2e",
        network: :none,
        restart: :never,
        containers: [%{name: "app", image: "alpine:latest", command: ["/bin/sleep", "60"]}]
      })

    # The reconciler started the runtime; the runtime brought the container up.
    :ok = Reconciler.sync(r)
    assert_receive {:tank, :running, host_pid}, 20_000
    assert File.dir?("/proc/#{host_pid}")
    assert %{"e2e" => _} = Reconciler.running(r)

    # Delete the desired state -> the reconciler stops the runtime -> the
    # container's process is gone.
    :ok = Tank.delete("e2e")
    :ok = Reconciler.sync(r)

    assert Reconciler.running(r) == %{}
    assert eventually(fn -> not File.dir?("/proc/#{host_pid}") end)
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(20) && false) end)
    |> Enum.find(fn ok -> ok || System.monotonic_time(:millisecond) > deadline end)
  end
end
