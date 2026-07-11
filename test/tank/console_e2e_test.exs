defmodule Tank.ConsoleE2ETest do
  # The web-facing console seam against reality: exec and attach as
  # byte-stream sessions (no Linx.Tty, no controlling terminal). Needs root.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.{Console, Reconciler}

  setup_all do
    deck = Tank.TestImages.deckhand!()
    dir = Path.join(System.tmp_dir!(), "tank-console-e2e-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, deck: deck, dir: dir}
  end

  setup %{deck: deck, dir: dir} do
    for pod <- Tank.list(), do: Tank.delete(pod.name)

    r =
      start_supervised!(
        {Reconciler,
         runtime: Tank.Runtime,
         owner: self(),
         runtime_opts: [image: deck.image_opts, data_dir: dir],
         interval: :timer.hours(1)}
      )

    {:ok, reconciler: r}
  end

  defp start_pod(r, deck, name, container_attrs \\ %{}) do
    container = Map.merge(%{name: "app", image: deck.ref}, container_attrs)

    :ok =
      Tank.apply(%{name: name, network: :none, restart: :never, containers: [container]})

    :ok = Reconciler.sync(r)
    assert_receive {:tank, ^name, {:running, host_pid}}, 20_000
    host_pid
  end

  defp collect_data(session, acc \\ "", timeout \\ 5_000) do
    receive do
      {:tank_console, ^session, {:data, bytes}} -> collect_data(session, acc <> bytes, timeout)
    after
      timeout -> acc
    end
  end

  test "exec joins the pod's cgroup — accounted and capped like the workload", %{
    reconciler: r,
    deck: deck
  } do
    keepalive_pid = start_pod(r, deck, "cg")

    {:ok, session} = Console.exec("cg", ["/bin/deckhand"])

    # The banner proves the exec'd process is past execve — which the session
    # only allows after joining the cgroup (checkpoint-ordered, no race).
    assert_receive {:tank_console, ^session, {:data, _banner}}, 20_000

    procs =
      "/sys/fs/cgroup/tank/cg/cgroup.procs"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.to_integer/1)

    assert keepalive_pid in procs
    assert length(procs) >= 2, "exec'd process missing from the pod cgroup: #{inspect(procs)}"

    :ok = Console.close(session)
  end

  test "exec: a byte-stream shell session — write, read, resize, exit", %{
    reconciler: r,
    deck: deck
  } do
    keepalive_pid = start_pod(r, deck, "cx")

    {:ok, session} = Console.exec("cx", ["/bin/deckhand"], cols: 120, rows: 30)

    # The REPL banner arrives as consumer data (never a terminal in sight).
    assert_receive {:tank_console, ^session, {:data, banner}}, 20_000
    assert banner != ""

    :ok = Console.resize(session, 100, 40)

    :ok = Console.write(session, "cat /etc/stevedore-test\n")
    :ok = Console.write(session, "exit\n")

    output = collect_data(session)
    assert output =~ "synthetic"

    # The REPL's exit ends the session: exit event, then closed, then gone.
    assert_receive {:tank_console, ^session, {:exit, {:exited, 0}}}, 10_000
    assert_receive {:tank_console, ^session, :closed}, 5_000
    refute Process.alive?(session)

    # The pod's main process is untouched.
    assert File.dir?("/proc/#{keepalive_pid}")

    Tank.delete("cx")
  end

  test "exec against a stopped pod refuses", %{reconciler: _r} do
    assert {:error, :not_running} = Console.exec("ghost", ["/bin/sh"])
  end

  test "attach: takes the main PTY, tees to the log, guards seconds, detaches clean", %{
    reconciler: r,
    deck: deck,
    dir: dir
  } do
    keepalive_pid = start_pod(r, deck, "at", %{tty: true})

    {:ok, session} = Console.attach("at", cols: 120, rows: 30)

    # Only one attacher at a time — the runtime guard.
    assert {:error, :attached} = Console.attach("at")

    # Drive the pod's main REPL through the session.
    :ok = Console.write(session, "cat /etc/stevedore-test\n")
    assert collect_data(session) =~ "synthetic"

    # Detach: session ends, pod keeps running, and a re-attach works.
    :ok = Console.close(session)
    assert_receive {:tank_console, ^session, :closed}, 5_000
    assert File.dir?("/proc/#{keepalive_pid}")

    {:ok, session2} = Console.attach("at")
    :ok = Console.close(session2)

    # The tee kept the log whole: the attach-driven output is in Tank.logs
    # as the :tty stream (the CLI-attach gap doesn't apply to web attach).
    {:ok, entries} = Tank.logs("at", dir: Path.join(dir, "logs"))
    assert Enum.any?(entries, &(&1.stream == :tty and &1.line =~ "synthetic"))

    Tank.delete("at")
  end

  test "a vanished consumer closes the session (pod survives an attach)", %{
    reconciler: r,
    deck: deck
  } do
    keepalive_pid = start_pod(r, deck, "cv", %{tty: true})

    test_pid = self()

    consumer =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    {:ok, session} = Console.attach("cv", consumer: consumer)
    ref = Process.monitor(session)

    send(consumer, :die)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

    # Detached, not killed — and attachable again.
    assert File.dir?("/proc/#{keepalive_pid}")
    {:ok, session2} = Console.attach("cv", consumer: test_pid)
    :ok = Console.close(session2)

    Tank.delete("cv")
  end
end
