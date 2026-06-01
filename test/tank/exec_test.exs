defmodule Tank.ExecTest do
  # Tank.exec/3's resolution path, without root: a pod that isn't running
  # resolves to {:error, :not_running}. The happy path (enter + PTY inside a
  # real container) lives in Tank.ExecE2ETest; the terminal pump itself is
  # Linx.Tty's to test.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # A stand-in for Tank.Runtime so the default reconciler can run without
  # bringing up containers. Mirrors Tank.ReconcilerTest.StubRuntime.
  defmodule StubRuntime do
    use GenServer

    def child_spec({pod, _opts}),
      do: %{id: {__MODULE__, pod.name}, start: {__MODULE__, :start_link, [pod]}}

    def start_link(pod), do: GenServer.start_link(__MODULE__, pod)

    @impl true
    def init(pod), do: {:ok, pod}
  end

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tank-exec-test-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)
    # The *default*-named reconciler, since Tank.exec resolves through it.
    start_supervised!({Tank.Reconciler, runtime: StubRuntime, interval: :timer.hours(1)})
    :ok
  end

  test "exec on a pod that isn't running returns {:error, :not_running}" do
    assert {:error, :not_running} = Tank.exec("ghost", ["/bin/sh"])
  end

  test "attach on a pod that isn't running returns {:error, :not_running}" do
    assert {:error, :not_running} = Tank.attach("ghost")
  end
end
