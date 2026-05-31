defmodule Tank.Image.Registry do
  @moduledoc """
  Minimal OCI Distribution (registry HTTP API v2) client.

  Covers exactly what an image pull needs:

    * an anonymous **bearer token** -- obtained from the `WWW-Authenticate`
      challenge a registry returns to an unauthenticated request;
    * a **manifest** fetch (an image index / manifest list, or a single image
      manifest);
    * a **blob** fetch by digest (a layer or the image config).

  The functions are stateless: `manifest/4` hands back the token it obtained,
  and the caller threads it into further `manifest/4` / `blob/4` calls.
  """

  @typedoc """
  A fetched manifest: its media type, content digest, raw bytes, and parsed
  JSON. `digest` is `nil` when the registry omitted the `Docker-Content-Digest`
  header (the caller computes it from `raw`).
  """
  @type info :: %{
          media_type: String.t() | nil,
          digest: String.t() | nil,
          raw: binary(),
          json: map()
        }

  @typedoc "An anonymous bearer token, or `nil` before one has been obtained."
  @type token :: String.t() | nil

  # Manifest media types this client understands -- sent in `Accept` so the
  # registry serves something we can parse, OCI or Docker, index or single.
  @manifest_types [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json"
  ]

  @doc """
  Fetches the manifest for `repo`:`reference` from `registry`.

  `reference` is a tag or a `sha256:` digest. `token` may be `nil` on the first
  call: a `401` response is answered by parsing its `WWW-Authenticate`
  challenge, exchanging it for an anonymous pull token, and retrying once.

  Returns `{:ok, info, token}` where `info` is
  `%{media_type:, digest:, raw:, json:}` and `token` is the (possibly newly
  obtained) bearer token, ready to thread into `blob/4`.
  """
  @spec manifest(String.t(), String.t(), String.t(), token()) ::
          {:ok, info(), token()} | {:error, term}
  def manifest(registry, repo, reference, token \\ nil) do
    url = "https://#{registry}/v2/#{repo}/manifests/#{reference}"
    headers = [{"accept", Enum.join(@manifest_types, ", ")} | auth(token)]

    case Req.get(url, headers: headers, raw: true) do
      {:ok, %{status: 200} = resp} ->
        raw = resp.body

        info = %{
          media_type: media_type(resp),
          digest: header(resp, "docker-content-digest"),
          raw: raw,
          json: JSON.decode!(raw)
        }

        {:ok, info, token}

      {:ok, %{status: 401, headers: headers}} when token == nil ->
        with {:ok, challenge} <- www_authenticate(headers),
             {:ok, new_token} <- exchange_token(challenge) do
          manifest(registry, repo, reference, new_token)
        end

      {:ok, %{status: status}} ->
        {:error, {:manifest_http, status}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  @doc """
  Downloads the blob `digest` (a `sha256:` string) from `repo` on `registry`.

  Returns `{:ok, bytes}`. Registries redirect blob requests to a CDN; Req
  follows the redirect and -- importantly -- drops the `Authorization` header
  when the redirect crosses to a different host, so the bearer token is never
  handed to the CDN.
  """
  @spec blob(String.t(), String.t(), String.t(), token()) :: {:ok, binary} | {:error, term}
  def blob(registry, repo, digest, token) do
    url = "https://#{registry}/v2/#{repo}/blobs/#{digest}"

    case Req.get(url, headers: auth(token), raw: true) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:blob_http, status}}
      {:error, exception} -> {:error, {:request_failed, exception}}
    end
  end

  # --- token exchange -------------------------------------------------------

  # Exchanges a parsed Bearer challenge for an anonymous pull token at the
  # token realm (`auth.docker.io/token` for Docker Hub).
  defp exchange_token(%{"realm" => realm} = challenge) do
    params =
      [service: challenge["service"], scope: challenge["scope"]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Req.get(realm, params: params, raw: true) do
      {:ok, %{status: 200, body: body}} ->
        decoded = JSON.decode!(body)

        case decoded["token"] || decoded["access_token"] do
          nil -> {:error, :no_token}
          token -> {:ok, token}
        end

      {:ok, %{status: status}} ->
        {:error, {:token_http, status}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp exchange_token(_challenge), do: {:error, :unsupported_auth}

  # Parses a `WWW-Authenticate: Bearer realm="...",service="...",scope="..."`
  # header into a map. Non-Bearer schemes are unsupported.
  defp www_authenticate(headers) do
    case header(headers, "www-authenticate") do
      "Bearer " <> params ->
        map =
          ~r/(\w+)="([^"]*)"/
          |> Regex.scan(params)
          |> Map.new(fn [_match, key, value] -> {key, value} end)

        {:ok, map}

      _ ->
        {:error, :unsupported_auth}
    end
  end

  # --- helpers --------------------------------------------------------------

  # The `Authorization` header list for a request, or [] when there is no token.
  defp auth(nil), do: []
  defp auth(token), do: [{"authorization", "Bearer #{token}"}]

  # First value of a response header. Req lowercases header names and stores
  # values in a list; accepts either a %Req.Response{} or a raw headers map.
  defp header(%Req.Response{headers: headers}, name), do: header(headers, name)

  defp header(headers, name) when is_map(headers) do
    case headers[name] do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # The manifest's media type: the Content-Type response header (parameters
  # stripped), falling back to the `mediaType` field inside the body.
  defp media_type(resp) do
    case header(resp, "content-type") do
      nil -> JSON.decode!(resp.body)["mediaType"]
      content_type -> content_type |> String.split(";") |> hd() |> String.trim()
    end
  end
end
