defmodule Tank.TestImages do
  @moduledoc false
  # Real distro images for the root e2e suites — a synthetic image can't
  # provide a shell. Never Docker Hub: the refs point at ECR's mirror of the
  # official images (no anonymous rate limit). Offline-first: the network is
  # touched only when the persistent cache is cold; warm runs pull nothing.
  #
  # Registry-*mechanics* tests don't belong here — they use the hermetic
  # local registry (`Stevedore.Testing`) and no external image at all.

  @cache Path.join(System.tmp_dir!(), "tank-image-cache")

  @alpine "public.ecr.aws/docker/library/alpine:latest"
  @debian "public.ecr.aws/docker/library/debian:13"

  def cache, do: @cache

  @doc "The alpine ref, for pod specs. Warm it first (`alpine!/0` in setup_all)."
  def alpine_ref, do: @alpine

  @doc "The debian ref, for pod specs. Warm it first (`debian!/0` in setup_all)."
  def debian_ref, do: @debian

  @doc "Warm (cold-cache only) and return {ref, pulled} for alpine."
  def alpine!, do: ensure!(@alpine)

  @doc "Warm (cold-cache only) and return {ref, pulled} for debian 13."
  def debian!, do: ensure!(@debian)

  @doc """
  Image opts for Runtime/Reconciler in tests: the shared cache, offline —
  after the setup_all warmed it, a pod start must not touch the network.
  """
  def image_opts, do: [cache: @cache, offline: true]

  defp ensure!(ref) do
    case Tank.Image.pull(ref, cache: @cache, offline: true) do
      {:ok, pulled} ->
        {ref, pulled}

      {:error, {:not_cached, _}} ->
        {:ok, pulled} = Tank.Image.pull(ref, cache: @cache)
        {ref, pulled}
    end
  end

  @doc """
  Seed a per-module cache with the runnable **deckhand** image, pulled from a
  hermetic local registry (`Stevedore.Testing` — the same `Stevedore.Server`
  that tankyard will run). Zero external network, ever. Call from `setup_all`;
  the registry, store, and cache are supervised/cleaned by ExUnit.

  Returns `%{ref:, cache:, image_opts:, pulled:}` — pods use `ref` with
  `image_opts` (offline: the cache was just warmed).
  """
  def deckhand! do
    reg = supervised_registry!()

    # An explicit PATH so exec-context env threading stays observable.
    {:ok, image} =
      Stevedore.Testing.runnable_image(
        config: %{entrypoint: ["/bin/deckhand"], cmd: [], env: ["PATH=/bin:/usr/bin"]}
      )

    ref = Stevedore.Testing.push!(reg, image, "tank/deckhand:latest")

    cache =
      Path.join(System.tmp_dir!(), "tank-deckhand-cache-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(cache) end)

    {:ok, pulled} = Tank.Image.pull(ref, cache: cache)
    %{ref: ref, cache: cache, image_opts: [cache: cache, offline: true], pulled: pulled}
  end

  @doc """
  A hermetic local registry supervised by the current ExUnit module/test —
  unlike `Stevedore.Testing.start_registry!/1` (linked to the caller), this
  survives `setup_all`'s process exiting. Returns the same registry map shape.
  """
  def supervised_registry! do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    store =
      Path.join(System.tmp_dir!(), "tank-test-registry-#{System.unique_integer([:positive])}")

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Stevedore.Server,
         store: store,
         port: port,
         authorize: fn _conn, _action, _scope -> :ok end,
         uploads: :"tank_test_registry_uploads_#{port}"}
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(store) end)
    %{registry: "localhost:#{port}", port: port, store: store, pid: pid}
  end
end
