defmodule Tank.ImageTest do
  use ExUnit.Case, async: false

  @ref "alpine:latest"

  # A persistent cache shared across runs, so repeated runs don't re-download
  # from the registry. Wiped only when forcing a refetch (TANK_IMAGE_REFRESH=1).
  @cache Path.join(System.tmp_dir!(), "tank-image-cache")

  describe "offline (no network)" do
    # An offline pull against an empty cache touches no registry, so this runs
    # in the default suite -- it covers the cache-miss path.
    test "a cache miss is reported, with no registry I/O" do
      empty =
        Path.join(System.tmp_dir!(), "tank-image-empty-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(empty) end)

      assert {:error, {:not_cached, "registry-1.docker.io/library/alpine:latest"}} =
               Tank.Image.pull(@ref, cache: empty, offline: true)
    end
  end

  describe "pull from a real registry" do
    # These reach Docker Hub -- run with `mix test --include network`. The
    # persistent @cache means only the first run downloads; later runs reuse it.
    @describetag :network

    setup do
      # Force a real refetch (ignoring cached blobs + rootfs) with
      #   TANK_IMAGE_REFRESH=1 mix test --include network
      if System.get_env("TANK_IMAGE_REFRESH") in ~w(1 true yes), do: File.rm_rf!(@cache)
      :ok
    end

    test "assembles a runnable alpine rootfs (cached for re-pulls)" do
      assert {:ok, %{rootfs: rootfs, config: config}} = Tank.Image.pull(@ref, cache: @cache)

      # the layer extracted into a real directory tree
      assert File.dir?(rootfs)
      assert File.exists?(Path.join(rootfs, "etc/alpine-release"))

      # alpine's absolute busybox symlinks survived extraction -- the whole
      # reason for the hand-rolled tar reader
      assert {:ok, "/bin/busybox"} = File.read_link(Path.join(rootfs, "bin/sh"))

      # the image config came back parsed
      assert config["architecture"] in ["amd64", "arm64"]
      assert is_list(config["config"]["Cmd"])
    end

    test "content-addressed -- a re-pull yields the same rootfs" do
      assert {:ok, %{rootfs: rootfs}} = Tank.Image.pull(@ref, cache: @cache)
      assert {:ok, %{rootfs: ^rootfs}} = Tank.Image.pull(@ref, cache: @cache)
    end

    test "offline serves the now-cached image with no network" do
      # warm the cache (online), then prove the offline path returns it
      assert {:ok, %{rootfs: rootfs}} = Tank.Image.pull(@ref, cache: @cache)

      assert {:ok, %{rootfs: ^rootfs, config: config}} =
               Tank.Image.pull(@ref, cache: @cache, offline: true)

      assert is_list(config["config"]["Cmd"])
    end
  end
end
