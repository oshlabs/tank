defmodule Tank.Runtime.VolumesTest do
  use ExUnit.Case, async: true

  alias Tank.{Container, Pod, Volume}
  alias Tank.Runtime.Volumes

  @moduletag :tmp_dir

  defp pod(volumes, mounts) do
    Pod.new!(
      name: "p",
      volumes: volumes,
      containers: [%{name: "c", image: "i:1", mounts: mounts}]
    )
  end

  defp container(%Pod{containers: [c]}), do: c

  test "a managed volume resolves under <data_dir>/volumes/<name> and is created",
       %{tmp_dir: dir} do
    p = pod([%{name: "data"}], [%{volume: "data", path: "/var/lib/data"}])

    assert {:ok, [resolved]} = Volumes.resolve(p, container(p), dir)
    assert resolved.source == Path.join([dir, "volumes", "data"])
    assert resolved.path == "/var/lib/data"
    assert resolved.read_only == false
    assert File.dir?(resolved.source)
  end

  test "managed volumes are keyed by name, not pod — stable across respecs",
       %{tmp_dir: dir} do
    p1 = pod([%{name: "data"}], [%{volume: "data", path: "/a"}])
    p2 = pod([%{name: "data"}], [%{volume: "data", path: "/b"}])

    {:ok, [r1]} = Volumes.resolve(p1, container(p1), dir)
    {:ok, [r2]} = Volumes.resolve(p2, container(p2), dir)
    assert r1.source == r2.source
  end

  test "a host volume must already exist", %{tmp_dir: dir} do
    src = Path.join(dir, "present")
    File.mkdir_p!(src)

    p =
      pod(
        [%{name: "ok", source: {:host, src}}, %{name: "gone", source: {:host, "/no/such/dir"}}],
        [
          %{volume: "ok", path: "/ok", read_only: true},
          %{volume: "gone", path: "/gone"}
        ]
      )

    assert {:error, {:volume_source_missing, "gone", "/no/such/dir"}} =
             Volumes.resolve(p, container(p), dir)

    # Alone, the existing one resolves — with read_only threaded through.
    p_ok =
      pod([%{name: "ok", source: {:host, src}}], [%{volume: "ok", path: "/ok", read_only: true}])

    assert {:ok, [%{source: ^src, path: "/ok", read_only: true}]} =
             Volumes.resolve(p_ok, container(p_ok), dir)
  end

  test "no mounts resolves to no work", %{tmp_dir: dir} do
    p = pod([%{name: "unused"}], [])
    assert {:ok, []} = Volumes.resolve(p, container(p), dir)
    # An unmounted volume is not materialized.
    refute File.dir?(Path.join([dir, "volumes", "unused"]))
  end

  test "a hand-built mount naming no volume is refused (totality)", %{tmp_dir: dir} do
    # Pod.new/1 validates references; resolve stays safe without it.
    container =
      Container.new!(%{name: "c", image: "i:1", mounts: [%{volume: "ghost", path: "/g"}]})

    p = %Pod{name: "p", containers: [container], volumes: [Volume.new!(%{name: "real"})]}

    assert {:error, {:unknown_volume, "ghost"}} = Volumes.resolve(p, container, dir)
  end
end
