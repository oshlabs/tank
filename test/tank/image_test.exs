defmodule Tank.ImageTest do
  # Registry mechanics against a hermetic local registry (Stevedore.Testing):
  # a Stevedore.Server on an ephemeral port serving a synthetic image. Real
  # HTTP pulls, zero external network — this module runs in the default suite.
  # Not async: the registry binds a port.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Stevedore.Testing

  describe "offline (no network)" do
    # An offline pull against an empty cache touches no registry, so these
    # exercise the cache-miss path with no server at all.
    test "a cache miss is reported, with no registry I/O" do
      empty =
        Path.join(System.tmp_dir!(), "tank-image-empty-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(empty) end)

      assert {:error, {:not_cached, "registry-1.docker.io/library/alpine:latest"}} =
               Tank.Image.pull("alpine:latest", cache: empty, offline: true)
    end

    test "with no :cache, the cache dir comes from config :tank, image_cache" do
      empty =
        Path.join(System.tmp_dir!(), "tank-image-cfg-#{System.unique_integer([:positive])}")

      previous = Application.get_env(:tank, :image_cache)
      Application.put_env(:tank, :image_cache, empty)

      on_exit(fn ->
        File.rm_rf!(empty)

        if previous,
          do: Application.put_env(:tank, :image_cache, previous),
          else: Application.delete_env(:tank, :image_cache)
      end)

      # No :cache option → default_cache reads the configured (empty) dir → miss.
      assert {:error, {:not_cached, _}} = Tank.Image.pull("alpine:latest", offline: true)
    end
  end

  describe "pull from a registry" do
    setup do
      reg = Testing.start_registry!()
      {:ok, image} = Testing.synthetic_image()
      ref = Testing.push!(reg, image, "tank/test:latest")

      cache =
        Path.join(System.tmp_dir!(), "tank-image-cache-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm_rf!(reg.store)
        File.rm_rf!(cache)
      end)

      %{ref: ref, cache: cache}
    end

    test "assembles a runnable rootfs from the pulled layers", %{ref: ref, cache: cache} do
      assert {:ok, %{rootfs: rootfs, config: config}} = Tank.Image.pull(ref, cache: cache)

      # the layer extracted into a real directory tree
      assert File.dir?(rootfs)
      assert File.read!(Path.join(rootfs, "etc/stevedore-test")) == "synthetic\n"

      # the absolute symlink survived extraction -- the whole reason for the
      # hand-rolled tar reader
      assert {:ok, "/bin/busybox"} = File.read_link(Path.join(rootfs, "bin/sh"))

      # the image config came back parsed
      assert config["config"]["Cmd"] == ["/bin/sh"]
    end

    test "content-addressed -- a re-pull yields the same rootfs", %{ref: ref, cache: cache} do
      assert {:ok, %{rootfs: rootfs}} = Tank.Image.pull(ref, cache: cache)
      assert {:ok, %{rootfs: ^rootfs}} = Tank.Image.pull(ref, cache: cache)
    end

    test "offline serves the now-cached image with no network", %{ref: ref, cache: cache} do
      # warm the cache (online), then prove the offline path returns it
      assert {:ok, %{rootfs: rootfs}} = Tank.Image.pull(ref, cache: cache)

      assert {:ok, %{rootfs: ^rootfs, config: config}} =
               Tank.Image.pull(ref, cache: cache, offline: true)

      assert config["config"]["Cmd"] == ["/bin/sh"]
    end

    test "a multi-arch index resolves to the host platform's manifest", %{cache: cache} do
      # Push deckhand for BOTH arches under a real OCI index; the pull must
      # walk index → platform manifest and land the host-arch image. This path
      # previously had no hermetic coverage (only real registries' indexes).
      reg = Tank.TestImages.supervised_registry!()
      {:ok, index} = Stevedore.Testing.runnable_image(platforms: :all)
      ref = "#{reg.registry}/tank/deckhand:multi"
      {:ok, _} = Stevedore.copy(index, "docker://" <> ref, all: true, scheme: "http")

      assert {:ok, %{rootfs: rootfs, config: config}} = Tank.Image.pull(ref, cache: cache)

      # The resolved image is the host platform's slice of the index...
      host_arch =
        case to_string(:erlang.system_info(:system_architecture)) do
          "x86_64" <> _ -> "amd64"
          "aarch64" <> _ -> "arm64"
        end

      assert config["architecture"] == host_arch

      # ...and its rootfs carries the runnable binary.
      assert File.exists?(Path.join(rootfs, "bin/deckhand"))
      assert config["config"]["Entrypoint"] == ["/bin/deckhand"]
    end

    test "logs honestly: 'pulling' on a miss, 'using cached' on a hit", %{ref: ref, cache: cache} do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      miss = capture_log(fn -> assert {:ok, _} = Tank.Image.pull(ref, cache: cache) end)
      assert miss =~ "tank: pulling"
      refute miss =~ "using cached"

      hit = capture_log(fn -> assert {:ok, _} = Tank.Image.pull(ref, cache: cache) end)
      assert hit =~ "tank: using cached"
      refute hit =~ "tank: pulling"
    end
  end
end
