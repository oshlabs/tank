defmodule Tank.StatsE2ETest do
  # The sampler against a real pod: cgroup accounting (for a NO-limits pod —
  # proving the always-create cgroup), netns interface counters, live events,
  # ring history, cleanup on delete. Needs root.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Tank.Reconciler

  setup_all do
    deck = Tank.TestImages.deckhand!()
    dir = Path.join(System.tmp_dir!(), "tank-stats-e2e-#{System.unique_integer([:positive])}")
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

    start_supervised!({Tank.Stats, interval: 200, coarse_interval: :timer.seconds(2)})

    {:ok, reconciler: r}
  end

  test "samples a running no-limits pod live and at rest, and forgets it on delete",
       %{reconciler: r, deck: deck} do
    :ok = Tank.Stats.subscribe("st")

    # No limits: the cgroup exists purely for accounting.
    :ok =
      Tank.apply(%{
        name: "st",
        network: :none,
        restart: :never,
        containers: [%{name: "app", image: deck.ref}]
      })

    :ok = Reconciler.sync(r)
    assert_receive {:tank, _, {:running, _host_pid}}, 20_000

    # Live: a sample with real cgroup accounting arrives...
    assert_receive {:tank_event, {:stats, "st"}, %{memory_bytes: mem} = first}, 10_000
    assert is_integer(mem) and mem > 0
    assert is_integer(first.pids) and first.pids >= 1
    # network :none is a fresh netns: readable (not nil, as :host would be),
    # holding nothing but the excluded lo.
    assert first.net == %{}

    # ...and once a previous sample exists, the derived rates fill in.
    assert_receive {:tank_event, {:stats, "st"}, %{cpu_percent: pct}}, 10_000
    assert is_float(pct)

    # At rest: current + raw history through the facade.
    assert {:ok, %{memory_bytes: m}} = Tank.stats("st")
    assert is_integer(m)
    assert [_ | _] = Tank.stats("st", window: :timer.minutes(1))

    # Delete → the sampler hears the :deleted event and drops the rows.
    :ok = Tank.delete("st")
    :ok = Reconciler.sync(r)
    assert eventually(fn -> Tank.stats("st") == {:error, :not_found} end)
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(20) && false) end)
    |> Enum.find(fn ok -> ok || System.monotonic_time(:millisecond) > deadline end)
  end
end
