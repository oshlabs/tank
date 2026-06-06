defmodule Tank.Image do
  @moduledoc """
  Pulls an OCI / Docker image and assembles it into a root filesystem a
  container can run from.

  `pull/2` resolves an image reference, downloads the manifest and blobs from
  the registry (`Tank.Image.Registry`), verifies every blob against its
  digest, and extracts the layers into a root filesystem directory:

      {:ok, %{rootfs: rootfs, config: config}} = Tank.Image.pull("alpine:latest")

  The returned `rootfs` is the directory the container runtime pivots into;
  `config` is the parsed image config (entrypoint / env / user / ...), returned
  for the runtime to apply — `pull/2` itself does not apply it.

  ## Caching

  Everything is cached on disk and survives restarts. The directory is the
  `:cache` option, else `config :tank, image_cache: …`, else `~/.cache/tank`:

    * `blobs/<algo>/<hex>` — layer and config blobs, content-addressed;
    * `rootfs/<digest>` — the assembled rootfs, keyed by the image manifest
      digest, so an already-assembled image is reused;
    * `refs/<ref>.json` — a small sidecar mapping a reference to its resolved
      manifest digest and parsed config, written on every successful online
      pull. It is what lets a fully-cached image be served with **no network
      I/O at all** via `offline: true`.

  An online pull always resolves the manifest (to follow a moving tag), but the
  heavy layer data downloads only on a cache miss — the log says `pulling` then,
  and `using cached <ref> (<digest>)` on a hit. So re-pulling an unchanged image
  fetches only the (small) manifest, never the layers or assembled rootfs;
  `offline: true` skips even the manifest and serves entirely from cache.

  Layers extract as the user running the BEAM, so a pulled image satisfies a
  root-remapped (userns) rootfs-ownership rule with no `chown`.

  Not yet handled: multi-layer whiteouts beyond a single directory's contents,
  and `/dev`-style runtime mounts (those are the container runtime's job).
  """

  require Logger

  alias Tank.Image.Registry

  @default_registry "registry-1.docker.io"

  # Media-type fragments that identify a multi-arch index / manifest list.
  @index_types ["image.index", "manifest.list"]

  @type pulled :: %{rootfs: Path.t(), config: map()}

  @typedoc """
  Options for `pull/2`:

    * `:cache` — cache directory (default: `config :tank, image_cache: …`, else
      `~/.cache/tank`).
    * `:offline` — when `true`, never touch the network: resolve the manifest,
      config and rootfs entirely from cache, returning
      `{:error, {:not_cached, ref}}` if the image isn't there. Default `false`.
    * `:refresh` — when `true`, ignore cached blobs and the assembled rootfs and
      re-fetch from the registry (a warm cache is otherwise reused). Default
      `false`. Mutually exclusive with `:offline`.
  """
  @type option :: {:cache, Path.t()} | {:offline, boolean()} | {:refresh, boolean()}

  @doc """
  Pulls `ref` and returns `{:ok, %{rootfs: path, config: config}}`.

  `ref` accepts `name`, `name:tag`, `registry/name:tag` and `name@sha256:...`;
  a bare name defaults to Docker Hub's `library/` namespace and the `latest`
  tag. `config` is the parsed image config JSON (not yet applied to the
  workload -- returned for a later high-level run API).

  See `t:option/0` for `:cache`, `:offline` and `:refresh`.
  """
  @spec pull(String.t(), [option]) :: {:ok, pulled()} | {:error, term}
  def pull(ref, opts \\ []) do
    cache = opts |> Keyword.get(:cache, default_cache()) |> Path.expand()
    parsed = parse_ref(ref)

    if Keyword.get(opts, :offline, false) do
      pull_offline(parsed, cache)
    else
      pull_online(parsed, cache, Keyword.get(opts, :refresh, false))
    end
  end

  # Serve a fully-cached image with no network I/O: the ref sidecar gives the
  # manifest digest + parsed config, and the assembled rootfs is keyed by that
  # digest. Anything missing is a cache miss.
  defp pull_offline(parsed, cache) do
    with {:ok, %{"digest" => digest, "config" => config}} <- read_ref(cache, parsed),
         rootfs = rootfs_path(cache, digest),
         true <- File.dir?(rootfs) or {:error, {:not_cached, ref_string(parsed)}} do
      {:ok, %{rootfs: rootfs, config: config}}
    else
      :error -> {:error, {:not_cached, ref_string(parsed)}}
      {:error, _} = error -> error
    end
  end

  defp pull_online(parsed, cache, refresh) do
    # One bearer token serves a whole pull (manifest + every blob share the repo's pull scope),
    # so a short-lived cache for the pull's duration avoids re-running the token handshake per
    # fetch. Threaded through as the registry client's auth handle; stopped when the pull ends.
    {:ok, token_cache} = Stevedore.Auth.Cache.start_link([])

    try do
      with {:ok, top, _echo} <-
             Registry.manifest(parsed.registry, parsed.repo, parsed.reference, token_cache),
           {:ok, image} <- resolve_platform(parsed, top, token_cache),
           _ = log_resolution(parsed, image.digest, cached_rootfs?(cache, image.digest, refresh)),
           {:ok, config} <- fetch_config(parsed, image, token_cache, cache, refresh),
           {:ok, rootfs} <- assemble_rootfs(parsed, image, token_cache, cache, refresh) do
        write_ref(cache, parsed, image.digest, config)
        {:ok, %{rootfs: rootfs, config: config}}
      end
    after
      Agent.stop(token_cache)
    end
  end

  # Honest logging: the manifest is resolved over the network every time (to
  # follow a moving tag), but the heavy layer data is downloaded only on a miss.
  defp cached_rootfs?(cache, digest, refresh),
    do: not refresh and File.dir?(rootfs_path(cache, digest))

  defp log_resolution(parsed, digest, true),
    do: Logger.info("tank: using cached #{ref_string(parsed)} (#{short_digest(digest)})")

  defp log_resolution(parsed, _digest, false),
    do: Logger.info("tank: pulling #{ref_string(parsed)}")

  defp short_digest("sha256:" <> hex), do: "sha256:" <> String.slice(hex, 0, 12)
  defp short_digest(digest), do: digest

  # --- manifest / platform --------------------------------------------------

  # A multi-arch index lists one manifest per platform: pick the entry matching
  # the host architecture and fetch that manifest. A single image manifest is
  # used as-is. Either way the manifest carries a `:digest` — the registry
  # client always resolves one (from the header, or computed from the bytes).
  defp resolve_platform(parsed, %{media_type: media_type} = manifest, token_cache) do
    if index?(media_type) do
      case pick_platform(manifest.json["manifests"]) do
        nil ->
          {:error, {:no_platform, host_platform()}}

        %{"digest" => digest} ->
          case Registry.manifest(parsed.registry, parsed.repo, digest, token_cache) do
            {:ok, image, _token_cache} -> {:ok, image}
            error -> error
          end
      end
    else
      {:ok, manifest}
    end
  end

  defp index?(media_type), do: Enum.any?(@index_types, &String.contains?(media_type, &1))

  # Find the index entry whose platform is the host's (linux + host arch).
  defp pick_platform(manifests) when is_list(manifests) do
    arch = host_arch()

    Enum.find(manifests, fn entry ->
      platform = entry["platform"] || %{}
      platform["os"] == "linux" and platform["architecture"] == arch
    end)
  end

  defp pick_platform(_manifests), do: nil

  # --- blobs ----------------------------------------------------------------

  # Download + parse the image config blob. The config (entrypoint, env, ...)
  # is not applied yet -- it is returned so a later run API can use it.
  defp fetch_config(parsed, image, token_cache, cache, refresh) do
    digest = image.json["config"]["digest"]

    with {:ok, path} <- fetch_blob(parsed, digest, token_cache, cache, refresh) do
      {:ok, JSON.decode!(File.read!(path))}
    end
  end

  # Extract every layer, in order, into a rootfs directory keyed by the image
  # manifest digest -- so an already-assembled image is reused. Extraction goes
  # into a `.tmp` sibling that is renamed into place only on full success.
  defp assemble_rootfs(parsed, image, token_cache, cache, refresh) do
    rootfs = rootfs_path(cache, image.digest)

    if File.dir?(rootfs) and not refresh do
      {:ok, rootfs}
    else
      File.rm_rf!(rootfs)
      tmp = rootfs <> ".tmp"
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      result =
        Enum.reduce_while(image.json["layers"], :ok, fn layer, :ok ->
          case extract_layer(parsed, layer["digest"], token_cache, cache, tmp, refresh) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      case result do
        :ok ->
          File.rename!(tmp, rootfs)
          {:ok, rootfs}

        error ->
          File.rm_rf!(tmp)
          error
      end
    end
  end

  # Fetch one layer blob and extract its gzipped tar into `dir`.
  defp extract_layer(parsed, digest, token_cache, cache, dir, refresh) do
    with {:ok, path} <- fetch_blob(parsed, digest, token_cache, cache, refresh) do
      case Tank.Image.Tar.extract(path, dir) do
        :ok -> :ok
        {:error, reason} -> {:error, {:extract, digest, reason}}
      end
    end
  end

  # Return a cached blob's path, downloading + verifying on a cache miss (or
  # always, when `refresh`). Blobs are content-addressed at cache/blobs/<algo>/<hex>.
  defp fetch_blob(parsed, digest, token_cache, cache, refresh) do
    path = blob_path(cache, digest)

    if not refresh and File.exists?(path) and verify(File.read!(path), digest) == :ok do
      {:ok, path}
    else
      # Stevedore already verified the downloaded bytes against `digest`; the
      # local verify above is the on-disk cache-integrity check (Stevedore isn't
      # in that path).
      with {:ok, body} <- Registry.blob(parsed.registry, parsed.repo, digest, token_cache) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body)
        {:ok, path}
      end
    end
  end

  # Check that `body` hashes to `digest`. OCI/Docker images use sha256.
  defp verify(body, "sha256:" <> hex) do
    if hex_sha256(body) == hex,
      do: :ok,
      else: {:error, {:digest_mismatch, "sha256:" <> hex}}
  end

  defp verify(_body, digest), do: {:error, {:unsupported_digest, digest}}

  defp hex_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp blob_path(cache, digest) do
    [algo, hex] = String.split(digest, ":", parts: 2)
    Path.join([cache, "blobs", algo, hex])
  end

  defp rootfs_path(cache, digest), do: Path.join([cache, "rootfs", safe_id(digest)])

  # A digest reused as a directory name -- drop the `sha256:` punctuation.
  defp safe_id(digest), do: String.replace(digest, ":", "_")

  # --- ref sidecar ----------------------------------------------------------

  # The ref->resolution sidecar records the manifest digest + parsed config a
  # reference resolved to, so `offline: true` can serve a cached image with no
  # network. Written on every successful online pull (a moving tag is updated
  # in place); read only in offline mode.
  defp write_ref(cache, parsed, digest, config) do
    path = ref_path(cache, parsed)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"digest" => digest, "config" => config}))
  end

  defp read_ref(cache, parsed) do
    case File.read(ref_path(cache, parsed)) do
      {:ok, body} -> {:ok, JSON.decode!(body)}
      {:error, _} -> :error
    end
  end

  defp ref_path(cache, parsed) do
    safe = ref_string(parsed) |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    Path.join([cache, "refs", safe <> ".json"])
  end

  defp ref_string(p), do: "#{p.registry}/#{p.repo}:#{p.reference}"

  # --- reference parsing ----------------------------------------------------

  # Split an image reference into registry / repository / (tag|digest):
  #   "alpine"            -> docker.io, library/alpine, latest
  #   "user/app:1.2"      -> docker.io, user/app, 1.2
  #   "ghcr.io/o/a:tag"   -> ghcr.io, o/a, tag
  #   "alpine@sha256:..." -> docker.io, library/alpine, sha256:...
  defp parse_ref(ref) do
    {registry, rest} = split_registry(ref)
    {repo, reference} = split_reference(rest)

    repo =
      if registry == @default_registry and not String.contains?(repo, "/"),
        do: "library/" <> repo,
        else: repo

    %{registry: registry, repo: repo, reference: reference}
  end

  # The first path segment is a registry only if it looks like a host: it
  # contains a dot or a port colon, or is exactly "localhost".
  defp split_registry(ref) do
    case String.split(ref, "/", parts: 2) do
      [maybe_registry, rest] ->
        if String.contains?(maybe_registry, ".") or
             String.contains?(maybe_registry, ":") or maybe_registry == "localhost",
           do: {maybe_registry, rest},
           else: {@default_registry, ref}

      [_only] ->
        {@default_registry, ref}
    end
  end

  # Separate the repository from a `@digest` or `:tag` suffix; default `latest`.
  defp split_reference(rest) do
    cond do
      String.contains?(rest, "@") ->
        [repo, digest] = String.split(rest, "@", parts: 2)
        {repo, digest}

      String.contains?(rest, ":") ->
        [repo, tag] = String.split(rest, ":", parts: 2)
        {repo, tag}

      true ->
        {rest, "latest"}
    end
  end

  # --- host / cache ---------------------------------------------------------

  defp host_platform, do: "linux/#{host_arch()}"

  # Map the BEAM's build triple (e.g. "x86_64-pc-linux-gnu") to an OCI
  # architecture string.
  defp host_arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "x86_64" <> _ -> "amd64"
      "aarch64" <> _ -> "arm64"
      "arm" <> _ -> "arm"
      other -> other |> String.split("-") |> hd()
    end
  end

  # The cache directory when the caller passes no `:cache`. A plain configurable
  # path (`config :tank, image_cache: …`), independent of the data dir; falls
  # back to the XDG user cache (`~/.cache/tank`).
  defp default_cache do
    Application.get_env(:tank, :image_cache) || xdg_cache()
  end

  defp xdg_cache do
    base = System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache")
    Path.join(base, "tank")
  end
end
