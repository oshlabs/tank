defmodule Tank.ExecE2ETest do
  # Tank.exec/3's mechanism against a real container: bring up a deckhand pod
  # (its keepalive), then enter its namespaces with a PTY (exactly what
  # Tank.exec does internally) and prove the exec runs *inside* the container
  # and leaves the pod's main process running. Needs root; hermetic — the
  # image comes from a local Stevedore registry, no network.
  #
  # We drive Linx.Process directly rather than calling Tank.exec/3, because
  # Tank.exec ends in Linx.Tty.attach(:group_leader, _) -- a terminal handover
  # that needs a real tty and is Linx.Tty's to test. Everything up to that
  # (resolve host pid -> enter + stdio: :pty) is Tank's, and is what we test.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Linx.Process, as: Workload
  alias Tank.{Reconciler, Runtime}


  setup_all do
    deck = Tank.TestImages.deckhand!()
    dir = Path.join(System.tmp_dir!(), "tank-exec-e2e-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, deck: deck}
  end

  setup %{deck: deck} do
    for pod <- Tank.list(), do: Tank.delete(pod.name)

    r =
      start_supervised!(
        {Reconciler,
         runtime: Tank.Runtime,
         owner: self(),
         runtime_opts: [image: deck.image_opts],
         interval: :timer.hours(1)}
      )

    {:ok, reconciler: r}
  end

  test "exec enters a running container's namespaces with a PTY", %{reconciler: r, deck: deck} do
    # A pod whose main process is a keepalive (deckhand's default: run until
    # signaled) -- the docker-exec model.
    :ok =
      Tank.apply(%{
        name: "ex",
        network: :none,
        restart: :never,
        containers: [%{name: "app", image: deck.ref}]
      })

    :ok = Reconciler.sync(r)
    assert_receive {:tank, :running, keepalive_pid}, 20_000

    # Resolve the running pod -> its container's exec context, exactly as
    # Tank.exec. The context's env is the *container's* (the image's Env).
    assert %{"ex" => runtime} = Reconciler.running(r)
    assert {:ok, ctx} = Runtime.exec_context(runtime)
    assert Enum.any?(ctx.env, &String.starts_with?(&1, "PATH=")), "container env has no PATH"

    # Enter all of the pod's namespaces with a PTY and run a *second* deckhand:
    # it finds the pod's main instance holding the port and degrades to
    # REPL-only — designed for exactly this exec scenario. Drive its REPL: the
    # marker file proves we're in the pod's rootfs, /proc/1/comm proves the
    # pod's pid namespace (the keepalive is pid 1).
    {:ok, session} =
      Workload.enter(ctx.host_pid,
        argv: ["/bin/deckhand"],
        env: ctx.env,
        stdio: :pty,
        auto_proceed: true
      )

    # Wait for the banner before writing — pty input races the exec otherwise.
    assert_receive {:linx_process, :pty_out, banner}, 20_000

    :ok = Workload.pty_write(session, "ifaces\n")
    :ok = Workload.pty_write(session, "cat /etc/stevedore-test\n")
    :ok = Workload.pty_write(session, "cat /proc/1/comm\n")
    :ok = Workload.pty_write(session, "exit\n")

    output = banner <> collect_pty(session)

    # The pod's main deckhand holds the port *in the pod's netns*, so the
    # exec'd one degrades to REPL-only — proof the exec joined the netns
    # (linx 0.1.0 silently didn't; the second instance bound the host's 8080).
    assert output =~ "REPL-only", "expected the port-taken degradation, got: #{inspect(output)}"

    # Belt and braces: the pod's netns (network: :none) has only loopback —
    # every interface line is lo, none of the host's NICs leak in.
    refute Regex.match?(~r/^(?!lo )\S+ inet/m, output),
           "expected only lo in the pod's netns, got: #{inspect(output)}"

    assert output =~ "synthetic", "expected the rootfs marker, got: #{inspect(output)}"
    # /proc/1/comm printed a line that is exactly "deckhand" (modulo the REPL
    # prompt — the banner also contains the word, so match a whole line).
    assert output =~ ~r/^(> )?deckhand\r?$/m,
           "expected the keepalive as pid 1, got: #{inspect(output)}"

    # The exec exited; the pod's main process is untouched.
    assert File.dir?("/proc/#{keepalive_pid}")

    Tank.delete("ex")
  end

  test "exec runs a one-shot applet to completion (exit + output propagate)",
       %{reconciler: r, deck: deck} do
    # The other exec shape: not an interactive REPL but a short-lived command
    # that prints and exits — the applet form of the old `sh -c` probe.
    :ok =
      Tank.apply(%{
        name: "ex1",
        network: :none,
        restart: :never,
        containers: [%{name: "app", image: deck.ref}]
      })

    :ok = Reconciler.sync(r)
    assert_receive {:tank, :running, _}, 20_000
    assert %{"ex1" => runtime} = Reconciler.running(r)
    assert {:ok, ctx} = Runtime.exec_context(runtime)

    {:ok, session} =
      Workload.enter(ctx.host_pid,
        argv: ["/bin/cat", "/etc/stevedore-test"],
        env: ctx.env,
        stdio: :pty,
        auto_proceed: true
      )

    output = collect_pty(session)
    assert output =~ "synthetic"

    Tank.delete("ex1")
  end

  # Pump :pty_out bytes until the exec session terminates, returning the
  # accumulated output.
  defp collect_pty(session, acc \\ "") do
    receive do
      {:linx_process, :pty_out, bytes} -> collect_pty(session, acc <> bytes)
      {:linx_process, :exited, _code} -> acc
      {:linx_process, :signaled, _signum} -> acc
    after
      20_000 -> flunk("exec session produced no terminal event; output so far: #{inspect(acc)}")
    end
  end
end
