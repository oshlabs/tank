defmodule Tank.Reconciler.Plan do
  @moduledoc false

  # The pure diff at the heart of the reconcile loop: given the desired pods and
  # what's currently running, decide what to start, stop, and restart. No side
  # effects, so it's exhaustively unit-testable.

  alias Tank.Pod

  @typedoc "name => the pod spec currently running under that name"
  @type running :: %{optional(String.t()) => Pod.t()}

  @type t :: %{start: [Pod.t()], stop: [String.t()], restart: [Pod.t()]}

  @doc """
  Diff `desired` (a list of pods) against `running` (name => running spec):

    * desired ∧ ¬running            → `:start` the pod
    * running ∧ ¬desired            → `:stop` it (by name)
    * running ∧ desired-but-changed → `:restart` it (the new spec)

  A pod "changed" iff its desired struct differs from the running one.
  """
  @spec diff([Pod.t()], running()) :: t()
  def diff(desired, running) do
    desired_by_name = Map.new(desired, &{&1.name, &1})
    desired_names = MapSet.new(Map.keys(desired_by_name))
    running_names = MapSet.new(Map.keys(running))

    start =
      for name <- MapSet.difference(desired_names, running_names), do: desired_by_name[name]

    stop = desired_names |> then(&MapSet.difference(running_names, &1)) |> MapSet.to_list()

    restart =
      for name <- MapSet.intersection(desired_names, running_names),
          desired_by_name[name] != running[name],
          do: desired_by_name[name]

    %{start: start, stop: stop, restart: restart}
  end
end
