defmodule Tank.Stats.Ring do
  @moduledoc false

  # The ETS shape behind Tank.Stats: one ordered_set holding, per pod,
  #
  #   {{pod, :current}, sample}
  #   {{pod, :raw, seq}, sample}      seq monotonic; ring by deleting seq-cap
  #   {{pod, :coarse, seq}, sample}   one folded sample per coarse interval
  #
  # Pure helpers — the sampler GenServer owns the table; tests drive these
  # against a private table without root or timing.

  @doc "Insert `sample` at `seq` for `(pod, resolution)`, evicting `seq - cap` — O(1) ring."
  @spec insert(:ets.table(), String.t(), :raw | :coarse, non_neg_integer(), map(), pos_integer()) ::
          :ok
  def insert(table, pod, resolution, seq, sample, cap) do
    :ets.insert(table, {{pod, resolution, seq}, sample})
    :ets.delete(table, {pod, resolution, seq - cap})
    :ok
  end

  @doc "Store the pod's newest sample."
  @spec put_current(:ets.table(), String.t(), map()) :: :ok
  def put_current(table, pod, sample) do
    :ets.insert(table, {{pod, :current}, sample})
    :ok
  end

  @spec current(:ets.table(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def current(table, pod) do
    case :ets.lookup(table, {pod, :current}) do
      [{_, sample}] -> {:ok, sample}
      [] -> {:error, :not_found}
    end
  end

  @doc "All samples of one resolution for a pod, oldest first."
  @spec samples(:ets.table(), String.t(), :raw | :coarse) :: [map()]
  def samples(table, pod, resolution) do
    # ordered_set: the {pod, resolution, seq} keys come out seq-ascending.
    :ets.select(table, [{{{pod, resolution, :_}, :"$1"}, [], [:"$1"]}])
  end

  @doc "Drop every row a pod owns (current + both rings)."
  @spec delete_pod(:ets.table(), String.t()) :: :ok
  def delete_pod(table, pod) do
    :ets.delete(table, {pod, :current})
    :ets.match_delete(table, {{pod, :_, :_}, :_})
    :ok
  end

  @doc """
  Fold one coarse bucket out of raw samples: numeric fields are averaged,
  `memory_peak_bytes` takes the max, `at`/`pod` come from the newest sample.
  `nil` fields stay nil unless some sample carried a value.
  """
  @spec fold([map()]) :: map() | nil
  def fold([]), do: nil

  def fold(samples) do
    newest = List.last(samples)

    %{
      newest
      | cpu_percent: mean(samples, :cpu_percent),
        memory_bytes: mean(samples, :memory_bytes),
        memory_peak_bytes: max_of(samples, :memory_peak_bytes),
        pids: mean(samples, :pids),
        rx_bytes_per_sec: mean(samples, :rx_bytes_per_sec),
        tx_bytes_per_sec: mean(samples, :tx_bytes_per_sec)
    }
  end

  defp values(samples, key), do: samples |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)

  defp mean(samples, key) do
    case values(samples, key) do
      [] -> nil
      vals -> Enum.sum(vals) / length(vals)
    end
  end

  defp max_of(samples, key) do
    case values(samples, key) do
      [] -> nil
      vals -> Enum.max(vals)
    end
  end
end
