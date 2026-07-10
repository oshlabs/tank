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
end
