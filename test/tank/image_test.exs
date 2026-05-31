defmodule Tank.ImageTest do
  use ExUnit.Case, async: false

  # These tests pull a real image from Docker Hub -- run with
  #   `mix test --include network`.
  @moduletag :network

  setup do
    cache = Path.join(System.tmp_dir!(), "tank-image-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(cache) end)
    {:ok, cache: cache}
  end

  test "pull/2 assembles a runnable alpine rootfs", %{cache: cache} do
    assert {:ok, %{rootfs: rootfs, config: config}} =
             Tank.Image.pull("alpine:latest", cache: cache)

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

  test "pull/2 is content-addressed -- a re-pull yields the same rootfs", %{cache: cache} do
    assert {:ok, %{rootfs: rootfs}} = Tank.Image.pull("alpine:latest", cache: cache)
    assert {:ok, %{rootfs: ^rootfs}} = Tank.Image.pull("alpine:latest", cache: cache)
  end
end
