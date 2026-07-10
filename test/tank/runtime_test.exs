defmodule Tank.RuntimeTest do
  # Pulls a real image and brings up a real container (rootfs + netns + cgroup):
  # needs root. Run via ./sudotest.sh.
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.{Pod, Runtime}


  setup_all do
    # Everything here runs the hermetic deckhand image (seeded through a local
    # Stevedore registry — zero network): the entrypoint REPL for keepalive/
    # interactive shapes, the busybox-style applets (/bin/exit, /bin/cat,
    # /bin/await-sig …) for run-to-completion shapes.
    deck = Tank.TestImages.deckhand!()
    {:ok, deck: deck}
  end

  # A deckhand pod. Without a :command the image entrypoint (REPL + server) is
  # the keepalive — runs until signaled; applets run to completion.
  defp deck_pod(name, deck, container_attrs \\ %{}, pod_attrs \\ %{}) do
    container = Map.merge(%{name: "app", image: deck.ref}, container_attrs)
    Pod.new!(Map.merge(%{name: name, network: :none, containers: [container]}, pod_attrs))
  end

  test "brings a pod to running with its rootfs, network, and cgroup limits", %{deck: deck} do
    p = deck_pod("rt-run", deck, %{limits: %{memory: 64 <<< 20, pids: 50}})

    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)

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

  test "a pod with no limits needs no cgroup", %{deck: deck} do
    p = deck_pod("rt-nolimits", deck)
    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)

    assert_receive {:tank, :running, _host_pid}, 15_000
    refute File.dir?("/sys/fs/cgroup/tank/rt-nolimits")

    GenServer.stop(runtime)
  end

  test "a workload killed by a signal stops under a :shutdown reason", %{deck: deck} do
    # The reconciler restarts off this reason (any non-:normal reason → restart
    # per policy); the :shutdown wrapper keeps OTP from logging a crash report.
    Process.flag(:trap_exit, true)

    p = deck_pod("rt-signal", deck)
    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
    assert_receive {:tank, :running, host_pid}, 15_000
    ref = Process.monitor(runtime)

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(host_pid)])

    assert_receive {:DOWN, ^ref, :process, ^runtime, reason}, 15_000
    assert reason == {:shutdown, {:workload_signaled, 9}}
  end

  test "a non-zero workload exit stops under a :shutdown reason (no crash report)", %{deck: deck} do
    # The workload ending is an expected outcome, not a Runtime crash, so the
    # GenServer stops under {:shutdown, _} — OTP logs no crash report — while the
    # reconciler still sees a non-:normal reason and restarts per policy.
    Process.flag(:trap_exit, true)

    p = deck_pod("rt-exit-code", deck, %{command: ["/bin/exit", "3"]}, %{restart: :never})
    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
    ref = Process.monitor(runtime)

    assert_receive {:DOWN, ^ref, :process, ^runtime, reason}, 15_000
    assert reason == {:shutdown, {:workload_exited, 3}}
  end

  test "a workload that exits cleanly on SIGTERM stops :normal (graceful shape)", %{deck: deck} do
    # await-sig: blocks until any signal, prints its details, exits 0 — the
    # graceful-shutdown shape (vs rt-signal's uncatchable KILL above). The
    # future drain hook's TERM should land pods here, not in :workload_signaled.
    Process.flag(:trap_exit, true)

    p = deck_pod("rt-graceful", deck, %{command: ["/bin/await-sig"]}, %{restart: :never})
    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
    assert_receive {:tank, :running, host_pid}, 15_000
    ref = Process.monitor(runtime)

    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(host_pid)])

    assert_receive {:DOWN, ^ref, :process, ^runtime, :normal}, 15_000
    assert_received {:tank, :exited, 0}
  end

  test "volumes: managed rw + host read-only, witnessed from inside", %{deck: deck} do
    data_dir = Path.join(System.tmp_dir!(), "tank-vol-#{System.unique_integer([:positive])}")
    host_src = Path.join(data_dir, "host-src")
    File.mkdir_p!(host_src)
    File.write!(Path.join(host_src, "shipped"), "hello-ro\n")
    on_exit(fn -> File.rm_rf!(data_dir) end)

    p =
      Pod.new!(%{
        name: "rt-vol",
        network: :none,
        volumes: [%{name: "data"}, %{name: "conf", source: {:host, host_src}}],
        containers: [
          %{
            name: "app",
            image: deck.ref,
            tty: true,
            mounts: [
              %{volume: "data", path: "/data"},
              %{volume: "conf", path: "/conf", read_only: true}
            ]
          }
        ]
      })

    {:ok, runtime} =
      Runtime.start_link(p, owner: self(), image: deck.image_opts, data_dir: data_dir)

    assert_receive {:tank, :running, _host_pid}, 15_000

    # The managed volume was allocated under data_dir; drop a probe in from
    # the host and read it back from inside the container (rw path), then
    # read the pre-shipped file through the read-only host mount.
    managed = Path.join([data_dir, "volumes", "data"])
    assert File.dir?(managed)
    File.write!(Path.join(managed, "probe"), "cargo\n")

    {:ok, session} = Runtime.begin_attach(runtime, self())
    :ok = Linx.Process.pty_write(session, "cat /data/probe\n")
    assert pty_contains?("cargo", 5_000)
    :ok = Linx.Process.pty_write(session, "cat /conf/shipped\n")
    assert pty_contains?("hello-ro", 5_000)

    # The pod's own /proc/mounts shows /conf sealed ro and /data rw.
    :ok = Linx.Process.pty_write(session, "mounts\n")
    {:ok, seen} = pty_until(~r{ /conf \S+ ro[,\s]}, 5_000)
    assert seen =~ ~r{ /data \S+ rw[,\s]}

    Runtime.end_attach(runtime)
    GenServer.stop(runtime)
  end

  describe "attach handoff (tty: true)" do
    test "begin_attach hands off the main PTY; detach leaves the workload running", %{deck: deck} do
      # The cat applet with no PATH echoes stdin: interactive, stays alive on
      # a PTY — the /bin/cat main-process shape, no distro needed.
      p = deck_pod("rt-attach", deck, %{command: ["/bin/cat"], tty: true})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
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

    test "a main process that exits during attach makes end_attach stop the runtime", %{deck: deck} do
      p = deck_pod("rt-attach-exit", deck, %{command: ["/bin/cat"], tty: true}, %{restart: :never})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
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

    test "begin_attach refuses a non-tty container with :not_a_tty", %{deck: deck} do
      p = deck_pod("rt-attach-notty", deck)
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
      assert_receive {:tank, :running, _host_pid}, 15_000

      assert {:error, :not_a_tty} = Runtime.begin_attach(runtime, self())

      GenServer.stop(runtime)
    end

    test "a tty container's main process gets a default TERM (so readline works)", %{deck: deck} do
      # The deckhand REPL as the tty main process; its `env` command shows the
      # environment the workload actually received — no shell expansion needed.
      p = deck_pod("rt-term", deck, %{tty: true})
      {:ok, runtime} = Runtime.start_link(p, owner: self(), image: deck.image_opts)
      assert_receive {:tank, :running, _host_pid}, 15_000

      {:ok, session} = Runtime.begin_attach(runtime, self())
      :ok = Linx.Process.pty_write(session, "env\n")
      assert pty_contains?("TERM=xterm", 5_000)

      Runtime.end_attach(runtime)
      GenServer.stop(runtime)
    end
  end

  # Accumulate :pty_out (delivered to this process while it owns the session)
  # until `needle` appears or the deadline passes.
  defp pty_contains?(needle, timeout) do
    pty_contains?(needle, "", System.monotonic_time(:millisecond) + timeout)
  end

  # Like pty_contains?/2 but regex-capable and returning the buffer, so a
  # caller can make several assertions against one burst of output.
  defp pty_until(regex, timeout) do
    pty_until(regex, "", System.monotonic_time(:millisecond) + timeout)
  end

  defp pty_until(regex, seen, deadline) do
    cond do
      seen =~ regex ->
        {:ok, seen}

      System.monotonic_time(:millisecond) > deadline ->
        flunk("pty: no match for #{inspect(regex)}; output so far: #{inspect(seen)}")

      true ->
        receive do
          {:linx_process, :pty_out, bytes} -> pty_until(regex, seen <> bytes, deadline)
        after
          100 -> pty_until(regex, seen, deadline)
        end
    end
  end

  defp pty_contains?(needle, seen, deadline) do
    cond do
      String.contains?(seen, needle) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        receive do
          {:linx_process, :pty_out, bytes} -> pty_contains?(needle, seen <> bytes, deadline)
        after
          200 -> pty_contains?(needle, seen, deadline)
        end
    end
  end
end
