defmodule Tank.Volume do
  @moduledoc """
  A pod-level storage volume, mounted into containers via `Tank.Mount`.

  Two sources:

    * `:managed` (default) — Tank allocates `<data_dir>/volumes/<name>`.
    * `{:host, path}` — bind-mount an existing absolute host directory (the
      escape hatch).
  """

  alias Tank.Validate

  @type source :: :managed | {:host, Path.t()}
  @type t :: %__MODULE__{name: String.t(), source: source()}

  @enforce_keys [:name]
  defstruct name: nil, source: :managed

  @keys [:name, :source]

  @doc "Build a validated volume from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, name} <- Validate.name(attrs[:name]),
         {:ok, source} <- source(Map.get(attrs, :source, :managed)) do
      {:ok, %__MODULE__{name: name, source: source}}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp source(:managed), do: {:ok, :managed}

  defp source({:host, path}) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, {:host, path}},
      else: {:error, {:host_path_not_absolute, path}}
  end

  defp source(other), do: {:error, {:invalid_source, other}}
end
