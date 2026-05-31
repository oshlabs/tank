defmodule Tank.Image.TarTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "tank-tar-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Build a gzipped tar at `path` from {name, content} pairs.
  defp layer(path, entries) do
    files = Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)
    :ok = :erl_tar.create(path, files, [:compressed])
    path
  end

  test "stacks layers, applying regular and opaque whiteouts", %{dir: dir} do
    rootfs = Path.join(dir, "rootfs")

    l1 =
      layer(Path.join(dir, "l1.tar.gz"), [
        {"keep.txt", "v1"},
        {"gone.txt", "gone"},
        {"d/old1.txt", "old1"},
        {"d/old2.txt", "old2"}
      ])

    l2 =
      layer(Path.join(dir, "l2.tar.gz"), [
        {".wh.gone.txt", ""},
        # delete keep.txt and re-add it in the same layer -- the re-add wins
        {".wh.keep.txt", ""},
        {"keep.txt", "v2"},
        {"added.txt", "added"}
      ])

    l3 =
      layer(Path.join(dir, "l3.tar.gz"), [
        # opaque marker: drop d/'s lower-layer contents, keep this layer's
        {"d/.wh..wh..opq", ""},
        {"d/new.txt", "new"}
      ])

    assert :ok = Tank.Image.Tar.extract(l1, rootfs)
    assert :ok = Tank.Image.Tar.extract(l2, rootfs)
    assert :ok = Tank.Image.Tar.extract(l3, rootfs)

    # regular whiteout removed a lower-layer file
    refute File.exists?(Path.join(rootfs, "gone.txt"))
    # delete-then-re-add in one layer nets to the new file
    assert File.read!(Path.join(rootfs, "keep.txt")) == "v2"
    assert File.read!(Path.join(rootfs, "added.txt")) == "added"
    # opaque marker dropped the directory's lower-layer contents...
    refute File.exists?(Path.join(rootfs, "d/old1.txt"))
    refute File.exists?(Path.join(rootfs, "d/old2.txt"))
    # ...but kept what its own layer added
    assert File.read!(Path.join(rootfs, "d/new.txt")) == "new"
    # the markers themselves are never written
    refute File.exists?(Path.join(rootfs, ".wh.gone.txt"))
    refute File.exists?(Path.join(rootfs, "d/.wh..wh..opq"))
  end
end
