defmodule Tank.ExecE2ETest do
  # Tank.exec/3's mechanism against a real container: bring up an alpine pod
  # with a keepalive, then enter its namespaces with a PTY (exactly what
  # Tank.exec does internally) and prove the exec runs *inside* the container
  # and leaves the pod's main process running. Needs root.
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

  @cache Path.join(System.tmp_dir!(), "tank-image-cache")

  setup_all do
    {:ok, _} = Tank.Image.pull("alpine:latest", cache: @cache)
    dir = Path.join(System.tmp_dir!(), "tank-exec-e2e-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)

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

  test "exec enters a running container's namespaces with a PTY", %{reconciler: r} do
    # A pod whose main process is a keepalive -- the docker-exec model.
    :ok =
      Tank.apply(%{
        name: "ex",
        network: :none,
        restart: :never,
        containers: [%{name: "app", image: "alpine:latest", command: ["/bin/sleep", "60"]}]
      })

    :ok = Reconciler.sync(r)
    assert_receive {:tank, :running, keepalive_pid}, 20_000

    # Resolve the running pod -> its container's exec context, exactly as
    # Tank.exec. The context's env is the *container's* (alpine's image Env),
    # so a bare `cat` resolves against the rootfs PATH with nothing hand-set.
    assert %{"ex" => runtime} = Reconciler.running(r)
    assert {:ok, ctx} = Runtime.exec_context(runtime)
    assert Enum.any?(ctx.env, &String.starts_with?(&1, "PATH=")), "container env has no PATH"

    # Enter all of the pod's namespaces with a PTY and run a command whose
    # output proves we are inside the alpine rootfs (the file only exists
    # there) and inside the pod's pid namespace (the keepalive is pid 1).
    {:ok, session} =
      Workload.enter(ctx.host_pid,
        argv: ["/bin/sh", "-c", "cat /etc/alpine-release; echo PID1=$(cat /proc/1/comm)"],
        env: ctx.env,
        stdio: :pty,
        auto_proceed: true
      )

    output = collect_pty(session)

    assert output =~ ~r/\d+\.\d+/, "expected an alpine version, got: #{inspect(output)}"
    assert output =~ "PID1=sleep", "expected the keepalive as pid 1, got: #{inspect(output)}"

    # The exec exited; the pod's main process is untouched.
    assert File.dir?("/proc/#{keepalive_pid}")

    Tank.delete("ex")
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
