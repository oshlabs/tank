defmodule Tank.Runtime.LogsTest do
  # The collector without a container: connect to its AF_UNIX listeners the
  # way linx's agent does and drive bytes through — no root needed.
  use ExUnit.Case, async: true

  alias Tank.Runtime.Logs, as: Collector

  setup do
    base = Path.join(System.tmp_dir!(), "tank-logs-#{System.unique_integer([:positive])}")
    scratch = Path.join(base, "run")
    log_dir = Path.join(base, "logs")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, scratch: scratch, log_dir: log_dir}
  end

  defp start_collector(pod, ctx, overrides \\ []) do
    {:ok, col} =
      Collector.maybe_start(pod, "app", ctx.scratch, ctx.base, [dir: ctx.log_dir] ++ overrides)

    col
  end

  defp connect!(path) do
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary])
    sock
  end

  test "captures stdout/stderr lines: file, broadcast, partial-line flush on EOF", ctx do
    pod = "logs-capture-#{System.unique_integer([:positive])}"
    col = start_collector(pod, ctx)
    :ok = Tank.Logs.subscribe(pod)

    [stdin: :devnull, stdout: {:connect_unix, out_path}, stderr: {:connect_unix, err_path}] =
      Collector.stdio(col)

    out = connect!(out_path)
    err = connect!(err_path)

    # A line split across writes is assembled; bytes after the newline wait.
    :ok = :gen_tcp.send(out, "hello ")
    :ok = :gen_tcp.send(out, "world\nsecond")
    :ok = :gen_tcp.send(err, "oops\n")

    assert_receive {:tank_logs, ^pod, %{container: "app", stream: :out, line: "hello world"}}
    assert_receive {:tank_logs, ^pod, %{container: "app", stream: :err, line: "oops"}}
    refute_received {:tank_logs, ^pod, %{line: "second"}}

    # EOF (workload exit) flushes the unterminated tail as a final line.
    :ok = :gen_tcp.close(out)
    assert_receive {:tank_logs, ^pod, %{stream: :out, line: "second"}}, 2_000

    :ok = :gen_tcp.close(err)
    :ok = Collector.stop(col)

    {:ok, entries} = Tank.logs(pod, dir: ctx.log_dir)
    by_stream = fn s -> for e <- entries, e.stream == s, do: e.line end
    assert by_stream.(:out) == ["hello world", "second"]
    assert by_stream.(:err) == ["oops"]
    assert Enum.all?(entries, &match?(%DateTime{}, &1.ts))
  end

  test "tees PTY output as :tty, shedding the CRLF", ctx do
    pod = "logs-tty-#{System.unique_integer([:positive])}"
    col = start_collector(pod, ctx)
    :ok = Tank.Logs.subscribe(pod)

    :ok = Collector.pty_out(col, "boot ok\r\ndo")
    :ok = Collector.pty_out(col, "ne")
    assert_receive {:tank_logs, ^pod, %{stream: :tty, line: "boot ok"}}

    # Stop flushes the partial "done".
    :ok = Collector.stop(col)

    {:ok, entries} = Tank.logs(pod, dir: ctx.log_dir)
    assert Enum.map(entries, & &1.line) == ["boot ok", "done"]
  end

  test "rotates by size and keeps at most max_files files", ctx do
    pod = "logs-rotate-#{System.unique_integer([:positive])}"
    # Every record (~27-byte stamp + tag + line) overflows 80 bytes quickly.
    col = start_collector(pod, ctx, max_file_bytes: 80, max_files: 3)

    [_, {:stdout, {:connect_unix, out_path}}, _] = Collector.stdio(col)
    out = connect!(out_path)

    for i <- 1..6, do: :ok = :gen_tcp.send(out, "line-number-#{i}\n")
    :ok = :gen_tcp.close(out)
    :ok = Collector.stop(col)

    log = Path.join([ctx.log_dir, pod, "app.log"])
    assert File.exists?(log)
    assert File.exists?(log <> ".1")
    assert File.exists?(log <> ".2")
    refute File.exists?(log <> ".3")

    # The tail read spans the current file plus one rotation back.
    {:ok, entries} = Tank.logs(pod, dir: ctx.log_dir, tail: 10)
    assert List.last(entries).line == "line-number-6"
    assert length(entries) >= 2
  end

  test "a stream that never writes a newline is force-flushed at the line cap", ctx do
    pod = "logs-cap-#{System.unique_integer([:positive])}"
    col = start_collector(pod, ctx)
    :ok = Tank.Logs.subscribe(pod)

    [_, {:stdout, {:connect_unix, out_path}}, _] = Collector.stdio(col)
    out = connect!(out_path)

    # 20 000 newline-less bytes: 16 KiB must flush as a line immediately
    # (bounding collector memory); the 3 616-byte remainder waits for EOF.
    :ok = :gen_tcp.send(out, String.duplicate("x", 20_000))
    assert_receive {:tank_logs, ^pod, %{stream: :out, line: line}}, 2_000
    assert byte_size(line) == 16_384

    :ok = :gen_tcp.close(out)
    :ok = Collector.stop(col)

    {:ok, entries} = Tank.logs(pod, dir: ctx.log_dir)
    assert Enum.map(entries, &byte_size(&1.line)) == [16_384, 20_000 - 16_384]
  end

  test "capture disabled: no collector, runtime falls back to :devnull", ctx do
    assert {:ok, nil} =
             Collector.maybe_start("logs-off", "app", ctx.scratch, ctx.base, enabled: false)

    assert :ok = Collector.stop(nil)
  end

  test "tail parses the on-disk format, skips torn lines, honors :tail", ctx do
    pod = "logs-parse"
    pod_dir = Path.join(ctx.log_dir, pod)
    File.mkdir_p!(pod_dir)

    File.write!(Path.join(pod_dir, "app.log.1"), """
    2026-07-10T10:00:00.000000Z out from-the-rotated-file
    """)

    File.write!(Path.join(pod_dir, "app.log"), """
    2026-07-10T10:00:01.000000Z out first
    garbage without a prefix
    2026-07-10T10:00:02.000000Z err second with spaces
    """)

    {:ok, entries} = Tank.logs(pod, dir: ctx.log_dir)

    assert Enum.map(entries, &{&1.stream, &1.line}) == [
             {:out, "from-the-rotated-file"},
             {:out, "first"},
             {:err, "second with spaces"}
           ]

    {:ok, [only]} = Tank.logs(pod, dir: ctx.log_dir, tail: 1)
    assert only.line == "second with spaces"

    # No logs at all is an empty list, not an error.
    assert {:ok, []} = Tank.logs("no-such-pod", dir: ctx.log_dir)
  end
end
