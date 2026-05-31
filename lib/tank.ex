defmodule Tank do
  @moduledoc """
  Tank — an opinionated, declarative container orchestrator built on Linx.

  You describe the pods that should run as Elixir data; Tank persists that
  desired state in Khepri and (from M4 on) a level-triggered loop converges the
  device to it. This module is the **runtime write API** over the desired state:

      Tank.apply(%{
        name: "web",
        containers: [%{name: "app", image: "nginx:1.27"}]
      })

      Tank.list()        #=> [%Tank.Pod{name: "web", …}]
      Tank.delete("web")

  `apply/1` accepts a `%Tank.Pod{}` or a plain spec map (validated via
  `Tank.Pod.new/1`); it writes to `[:tank, :pods, name]` in the store. You never
  imperatively start a container — you state intent and the reconciler converges.

  ## Architecture

    * `Tank.Pod` and friends — the typed desired-state model.
    * `Tank.Store` — the Khepri seam (the source of truth) + an ETS projection.
    * `Tank.Runtime` — the per-container actuator (`Linx.Process` + `Rtnl`),
      the M2 proof of concept that M4 grows into the pod actuator.

  Tank is a separate mix app with a *path* dependency on Linx, so it reaches
  **only Linx's public API**; a gap in the primitives surfaces here, early.

  ## Bootstrap vs. runtime

  Khepri is the source of truth. `config/runtime.exs` only *seeds* pods
  create-if-absent on a fresh store (see `Tank.Application`), so the boot seed
  never clobbers state changed at runtime via `apply/1` / `delete/1`.
  """

  require Logger

  alias Tank.{Pod, Store}

  @type spec :: Pod.t() | map() | keyword()

  @doc """
  Declare a pod's desired state — create it or replace it. Accepts a
  `%Tank.Pod{}` or a spec map/keyword list (validated via `Tank.Pod.new/1`).
  """
  @spec apply(spec()) :: :ok | {:error, term()}
  def apply(spec) do
    with {:ok, pod} <- to_pod(spec), do: Store.put_pod(pod)
  end

  @doc "Remove a pod's desired state, by name or by `%Tank.Pod{}`."
  @spec delete(String.t() | Pod.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name), do: Store.delete_pod(name)
  def delete(%Pod{name: name}), do: Store.delete_pod(name)

  @doc "Fetch one declared pod by name."
  @spec get(String.t()) :: {:ok, Pod.t()} | {:error, :not_found}
  def get(name) when is_binary(name), do: Store.get_pod(name)

  @doc "Every declared pod (a fast read through the store's projection)."
  @spec list() :: [Pod.t()]
  def list, do: Store.list_pods()

  @doc false
  # Bootstrap seed: write each spec create-if-absent, so config never clobbers
  # runtime-changed state. Invalid specs and write failures are logged, not
  # raised -- a bad entry in the seed list shouldn't take down the node.
  @spec seed([spec()]) :: :ok
  def seed(specs) when is_list(specs) do
    Enum.each(specs, fn spec ->
      with {:ok, pod} <- to_pod(spec),
           result when result in [:ok, {:error, :exists}] <- Store.create_pod(pod) do
        :ok
      else
        {:error, reason} -> Logger.warning("Tank: skipping seed pod: #{inspect(reason)}")
      end
    end)
  end

  defp to_pod(%Pod{} = pod), do: {:ok, pod}
  defp to_pod(spec) when is_map(spec) or is_list(spec), do: Pod.new(spec)
  defp to_pod(other), do: {:error, {:invalid_pod_spec, other}}
end
