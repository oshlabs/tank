defmodule Tank.AttachFlagshipTest do
  # The M5.5 success criterion, on the named image: a real debian 13 container
  # whose main process *is* bash, attached over a PTY, driven interactively,
  # then detached with the container still running. Needs root + network (the
  # image pull). The interactive human steps (typing, Ctrl-P Ctrl-Q) are driven
  # here through the same primitives Tank.attach/1 uses.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  alias Linx.Process, as: Workload
  alias Tank.{Pod, Runtime}

  setup_all do
    {_ref, _} = Tank.TestImages.debian!()
    :ok
  end

  test "attach to a debian 13 bash, drive it, detach leaving it running" do
    p =
      Pod.new!(%{
        name: "flagship",
        network: :none,
        restart: :always,
        containers: [
          %{name: "sh", image: Tank.TestImages.debian_ref(), command: ["/bin/bash"], tty: true}
        ]
      })

    {:ok, runtime} = Runtime.start_link(p, owner: self(), image: Tank.TestImages.image_opts())
    assert_receive {:tank, :running, _host_pid}, 30_000

    # Take over the main bash's terminal (what Tank.attach/1 does internally).
    {:ok, session} = Runtime.begin_attach(runtime, self())

    # Drive the interactive shell and read its output back over the PTY — proof
    # it is a real debian rootfs running a real bash.
    :ok = Workload.pty_write(session, "cat /etc/os-release\n")
    assert collect_until("Debian GNU/Linux 13", 10_000)

    # Detach (the human's Ctrl-P Ctrl-Q; here we just hand ownership back): the
    # container keeps running, ready to re-attach.
    :ok = Runtime.end_attach(runtime)
    assert Process.alive?(runtime)
    assert {:ok, %{stage: :running}} = Workload.info(session)

    GenServer.stop(runtime)
  end

  # Accumulate :pty_out until `needle` appears or the deadline passes.
  defp collect_until(needle, timeout) do
    collect_until(needle, "", System.monotonic_time(:millisecond) + timeout)
  end

  defp collect_until(needle, seen, deadline) do
    cond do
      String.contains?(seen, needle) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never saw #{inspect(needle)}; saw: #{inspect(seen)}")

      true ->
        receive do
          {:linx_process, :pty_out, bytes} -> collect_until(needle, seen <> bytes, deadline)
        after
          200 -> collect_until(needle, seen, deadline)
        end
    end
  end
end
