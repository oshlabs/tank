defmodule Tank.Validate do
  @moduledoc false

  # Internal validation helpers shared by the Tank desired-state structs
  # (`Tank.Pod` and friends). Each returns `{:ok, value}` or `{:error, reason}`
  # so the per-struct `new/1` functions can thread them with `with`.

  @doc """
  Every key of `attrs` must appear in `allowed` -- a typo'd field is an error,
  not silently ignored.
  """
  def keys(attrs, allowed) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_keys, Enum.sort(unknown)}}
    end
  end

  @doc "A non-empty binary -- the shape of every resource name."
  def name(v) when is_binary(v) and v != "", do: {:ok, v}
  def name(v), do: {:error, {:invalid_name, v}}

  @doc "A dotted-quad IPv4 string."
  def ipv4(v) when is_binary(v) do
    case :inet.parse_ipv4_address(String.to_charlist(v)) do
      {:ok, _} -> {:ok, v}
      {:error, _} -> {:error, {:invalid_ipv4, v}}
    end
  end

  def ipv4(v), do: {:error, {:invalid_ipv4, v}}

  @doc "A list whose elements are all binaries."
  def strings(v) when is_list(v) do
    if Enum.all?(v, &is_binary/1), do: {:ok, v}, else: {:error, {:not_a_string_list, v}}
  end

  def strings(v), do: {:error, {:not_a_string_list, v}}

  @doc "`value` must be a member of `allowed`."
  def one_of(value, allowed) do
    if value in allowed, do: {:ok, value}, else: {:error, {:not_allowed, value, allowed}}
  end

  @doc "No two items in `items` share the same value under `fun`."
  def unique(items, fun) do
    keys = Enum.map(items, fun)

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      dupes -> {:error, {:duplicate, Enum.uniq(dupes)}}
    end
  end

  @doc """
  Normalise each element of `list` into a `module` struct via `module.new/1`,
  passing existing structs through untouched. Halts on the first error.
  """
  def build_list(list, module) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case build(item, module) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      err -> err
    end
  end

  def build_list(other, _module), do: {:error, {:not_a_list, other}}

  @doc "Normalise a single item into a `module` struct (pass through if already one)."
  def build(%mod{} = struct, mod), do: {:ok, struct}
  def build(attrs, module) when is_map(attrs) or is_list(attrs), do: module.new(attrs)
  def build(other, module), do: {:error, {:cannot_build, module, other}}

  @doc "Body for a struct's `new!/1`: call `module.new/1`, raise on error."
  def bang(module, attrs) do
    case module.new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid #{inspect(module)}: #{inspect(reason)}"
    end
  end
end
