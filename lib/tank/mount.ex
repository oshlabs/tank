defmodule Tank.Mount do
  @moduledoc """
  A `Tank.Volume` mounted into a container at an absolute in-rootfs `path`.

  `volume` names a pod-level `Tank.Volume`; `Tank.Pod.new/1` checks that the
  reference resolves to a defined volume.
  """

  alias Tank.Validate

  @type t :: %__MODULE__{volume: String.t(), path: String.t(), read_only: boolean()}

  @enforce_keys [:volume, :path]
  defstruct volume: nil, path: nil, read_only: false

  @keys [:volume, :path, :read_only]

  @doc "Build a validated mount from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, volume} <- Validate.name(attrs[:volume]),
         {:ok, path} <- abs_path(attrs[:path]),
         {:ok, read_only} <- boolean(Map.get(attrs, :read_only, false)) do
      {:ok, %__MODULE__{volume: volume, path: path, read_only: read_only}}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp abs_path(p) when is_binary(p) do
    if Path.type(p) == :absolute, do: {:ok, p}, else: {:error, {:mount_path_not_absolute, p}}
  end

  defp abs_path(p), do: {:error, {:invalid_mount_path, p}}

  defp boolean(b) when is_boolean(b), do: {:ok, b}
  defp boolean(b), do: {:error, {:invalid_read_only, b}}
end
