defmodule Tank.StatsTest do
  # The pure ring/fold machinery behind Tank.Stats — no root, no timing.
  use ExUnit.Case, async: true

  alias Tank.Stats.Ring

  defp sample(n, over \\ %{}) do
    Map.merge(
      %{
        pod: "p",
        at: DateTime.add(~U[2026-07-10 12:00:00Z], n, :second),
        cpu_usec: n * 1000,
        cpu_percent: n * 1.0,
        memory_bytes: 100 + n,
        memory_peak_bytes: 100 + n,
        pids: 5,
        net: nil,
        rx_bytes_per_sec: n * 10.0,
        tx_bytes_per_sec: nil
      },
      over
    )
  end

  setup do
    {:ok, table: :ets.new(:stats_ring_test, [:ordered_set, :public])}
  end

  test "raw ring keeps at most cap samples, oldest evicted, oldest-first reads", %{table: t} do
    for n <- 0..9, do: Ring.insert(t, "p", :raw, n, sample(n), 5)

    kept = Ring.samples(t, "p", :raw)
    assert length(kept) == 5
    assert Enum.map(kept, & &1.cpu_usec) == [5000, 6000, 7000, 8000, 9000]
  end

  test "rings and current are per pod, and delete_pod drops everything", %{table: t} do
    Ring.insert(t, "a", :raw, 0, sample(1), 10)
    Ring.insert(t, "a", :coarse, 0, sample(2), 10)
    Ring.put_current(t, "a", sample(3))
    Ring.insert(t, "b", :raw, 0, sample(4), 10)

    assert {:ok, %{cpu_usec: 3000}} = Ring.current(t, "a")
    assert [_] = Ring.samples(t, "a", :coarse)

    Ring.delete_pod(t, "a")
    assert {:error, :not_found} = Ring.current(t, "a")
    assert [] = Ring.samples(t, "a", :raw)
    assert [] = Ring.samples(t, "a", :coarse)
    # "b" untouched
    assert [_] = Ring.samples(t, "b", :raw)
  end

  test "fold averages rates, maxes the peak, and keeps the newest timestamp" do
    folded =
      Ring.fold([
        sample(1, %{memory_peak_bytes: 500}),
        sample(2),
        sample(3, %{cpu_percent: nil})
      ])

    # cpu 1.0 + 2.0 over two non-nil values.
    assert folded.cpu_percent == 1.5
    assert folded.memory_peak_bytes == 500
    assert folded.rx_bytes_per_sec == 20.0
    # tx was nil throughout — stays nil, not 0.
    assert folded.tx_bytes_per_sec == nil
    assert folded.at == sample(3).at
  end

  test "fold of nothing is nil" do
    assert Ring.fold([]) == nil
  end

  test "public reads degrade cleanly when the sampler isn't running" do
    # Test env starts no store branch, hence no Tank.Stats — the named table
    # doesn't exist and the reads answer honestly.
    assert {:error, :not_found} = Tank.stats("nope")
    assert [] = Tank.stats("nope", window: :timer.minutes(1))
  end
end
