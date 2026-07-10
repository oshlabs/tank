defmodule Tank.Runtime.RootfsTest do
  # Real mounts + a real container: needs root. Run via ./sudotest.sh.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.Runtime.Rootfs

  setup_all do
    {_ref, %{rootfs: rootfs}} = Tank.TestImages.alpine!()
    {:ok, rootfs: rootfs}
  end

  test "brings up an alpine rootfs and the workload runs inside it", %{rootfs: rootfs} do
    # Capture the probe via a file written into the rootfs (a host dir we can
    # read back) -- a host unix socket would be unreachable after pivot_root.
    outfile = "tank-probe-#{System.unique_integer([:positive])}.out"
    on_exit(fn -> File.rm(Path.join(rootfs, outfile)) end)

    # Probe the pivoted rootfs: image marker, /dev nodes, container-pidns /proc.
    probe =
      "{ cat /etc/alpine-release; " <>
        "echo DEV=$(ls /dev | sort | tr '\\n' ','); " <>
        "echo SELF=$(cut -d' ' -f1 /proc/self/stat); } > /#{outfile}"

    {:ok, session} =
      Linx.Process.spawn(
        argv: ["/bin/sh", "-c", probe],
        namespaces: [:mount, :pid, :uts],
        cwd: "/",
        env: ["PATH=/usr/sbin:/usr/bin:/sbin:/bin"],
        stdio: :devnull
      )

    assert_receive {:linx_process, :ready, host_pid}, 2_000
    assert :ok = Rootfs.setup(host_pid, rootfs)
    :ok = Linx.Process.proceed(session)

    assert_receive {:linx_process, :exited, 0}, 5_000

    out = File.read!(Path.join(rootfs, outfile))

    # The pivot landed us in the alpine rootfs.
    assert out =~ ~r/^\d+\.\d+\.\d+/, "expected an alpine-release version, got: #{inspect(out)}"

    # /dev was populated with the standard device nodes.
    assert out =~ "null" and out =~ "zero" and out =~ "urandom" and out =~ "tty"

    # /proc reflects the *container's* PID namespace: the shell is a tiny pid.
    assert [_, self_pid] = Regex.run(~r/SELF=(\d+)/, out)
    assert String.to_integer(self_pid) < 100
  end
end
