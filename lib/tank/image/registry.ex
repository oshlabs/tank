defmodule Tank.Image.Registry do
  @moduledoc """
  OCI registry access for image pulls — a thin shim over `Stevedore.Registry`.

  Tank fetches all OCI data through Stevedore. This module preserves the
  historical return contracts so the rest of `Tank.Image` is unchanged:

    * `manifest/4` → `{:ok, info, token}` (an image index / manifest list, or a
      single image manifest);
    * `blob/4` → `{:ok, bytes}` (a layer or the image config).

  The bearer-token handshake, manifest fetch, and digest-verified blob download
  all live in Stevedore now; the `token` argument is inert (see `t:token/0`).
  """

  alias Stevedore.{Digest, Reference}
  alias Stevedore.Registry, as: OCI
  alias Stevedore.Registry.Error

  @typedoc """
  A fetched manifest: its media type, content digest, raw bytes, and parsed
  JSON. `digest` is always a `"sha256:…"` string now — Stevedore computes it
  from `raw` when the registry omits the `Docker-Content-Digest` header.
  """
  @type info :: %{
          media_type: String.t() | nil,
          digest: String.t(),
          raw: binary(),
          json: map()
        }

  @typedoc """
  Formerly the anonymous bearer token threaded across calls. Stevedore manages
  auth internally now, so this is inert — kept for signature compatibility and
  echoed back unchanged.
  """
  @type token :: String.t() | nil

  @doc """
  Fetches the manifest for `repo`:`reference` from `registry`.

  `reference` is a tag or a `sha256:` digest. Returns `{:ok, info, token}`,
  where `token` is echoed back unchanged (Stevedore performs auth internally).
  """
  @spec manifest(String.t(), String.t(), String.t(), token()) ::
          {:ok, info(), token()} | {:error, term}
  def manifest(registry, repo, reference, token \\ nil) do
    case OCI.manifest(ref(registry, repo, reference)) do
      {:ok, %{media_type: mt, digest: digest, raw: raw, json: json}} ->
        {:ok, %{media_type: mt, digest: to_string(digest), raw: raw, json: json}, token}

      {:error, error} ->
        {:error, translate(error, :manifest)}
    end
  end

  @doc """
  Downloads the blob `digest` (a `sha256:` string) from `repo` on `registry`.

  Returns `{:ok, bytes}`. Stevedore verifies the bytes against `digest` and
  drops the `Authorization` header across CDN redirects, so the blob arrives
  already-verified and the token is never handed to the CDN.
  """
  @spec blob(String.t(), String.t(), String.t(), token()) :: {:ok, binary} | {:error, term}
  def blob(registry, repo, digest, _token) do
    with {:ok, d} <- Digest.parse(digest),
         {:ok, bytes} <- OCI.blob(ref(registry, repo, nil), d) do
      {:ok, bytes}
    else
      {:error, %Error{} = error} -> {:error, translate(error, :blob)}
      {:error, other} -> {:error, other}
    end
  end

  # --- helpers --------------------------------------------------------------

  # Build a Stevedore.Reference from Tank's already-normalized parts. The Docker
  # Hub default and `library/` prefix are applied upstream in
  # `Tank.Image.parse_ref/1`, so we construct the struct directly rather than
  # re-parsing (which would normalize a second time). `reference` is a tag, a
  # `"sha256:…"` digest, or `nil` (for blob fetches, which carry the digest
  # separately).
  defp ref(registry, repo, reference) do
    {tag, digest} = tag_or_digest(reference)
    %Reference{registry: registry, repository: repo, tag: tag, digest: digest}
  end

  defp tag_or_digest(nil), do: {nil, nil}

  defp tag_or_digest(reference) do
    case Digest.parse(reference) do
      {:ok, digest} -> {nil, digest}
      {:error, _} -> {reference, nil}
    end
  end

  # Map Stevedore's %Error{} back to the tuples Tank's pull path historically
  # returned, so callers and tests see unchanged error shapes.
  defp translate(%Error{reason: :digest_mismatch}, _kind), do: {:digest_mismatch, :blob}
  defp translate(%Error{status: s}, :manifest) when is_integer(s), do: {:manifest_http, s}
  defp translate(%Error{status: s}, :blob) when is_integer(s), do: {:blob_http, s}
  defp translate(error, _kind), do: {:request_failed, error}
end
