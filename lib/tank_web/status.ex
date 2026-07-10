defmodule TankWeb.Status do
  @moduledoc """
  Pure helpers merging desired state (`Tank.list/0`) with observed state
  (`Tank.Reconciler.status/0`) into the rows the screens render.

  Interim seam: Phase B replaces the merge with `Tank.status/0` (the domain
  facade with last-exit info and events); these helpers then shrink to
  presentation concerns (badge colors, age formatting).
  """

  @type row :: %{
          name: String.t(),
          pod: Tank.Pod.t(),
          status: :pending | :running | :backing_off | :terminal,
          retries: non_neg_integer()
        }

  @spec rows() :: [row()]
  def rows do
    observed = observed()

    Tank.list()
    |> Enum.map(fn pod ->
      obs = Map.get(observed, pod.name, %{})

      %{
        name: pod.name,
        pod: pod,
        status: Map.get(obs, :status, :pending),
        retries: Map.get(obs, :retries, 0)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # The reconciler may be down (headless-degraded boot, tests): the UI then
  # honestly shows everything :pending rather than crashing.
  defp observed do
    Tank.Reconciler.status()
  catch
    :exit, _ -> %{}
  end

  @doc "Gooey badge color for a pod status."
  @spec badge_color(atom()) :: String.t()
  def badge_color(:running), do: "success"
  def badge_color(:backing_off), do: "warning"
  def badge_color(:terminal), do: "error"
  def badge_color(_), do: "neutral"

  @doc "Counts per status, for the stat tiles."
  @spec counts([row()]) :: %{atom() => non_neg_integer()}
  def counts(rows), do: Enum.frequencies_by(rows, & &1.status)
end
