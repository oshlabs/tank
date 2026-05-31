defmodule Tank.Pod.Network do
  @moduledoc """
  A pod's network namespace: a set of interfaces plus pod-level DNS (one
  `/etc/resolv.conf` per netns). Loopback is always raised by the runtime.

  As a *whole*, a pod's `:network` may instead be the atom `:host` (share the
  host's network namespace) or `:none` (an isolated netns, loopback only);
  those shortcuts are handled by `Tank.Pod`, not here.
  """

  alias Tank.{Nic, Validate}

  @type t :: %__MODULE__{nics: [Nic.t()], dns: [String.t()]}

  defstruct nics: [], dns: []

  @keys [:nics, :dns]

  @doc "Build a validated pod network from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, nics} <- Validate.build_list(Map.get(attrs, :nics, []), Nic),
         :ok <- Validate.unique(nics, & &1.name),
         {:ok, dns} <- dns(Map.get(attrs, :dns, [])) do
      {:ok, %__MODULE__{nics: nics, dns: dns}}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp dns(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn addr, {:ok, acc} ->
      case Validate.ipv4(addr) do
        {:ok, _} -> {:cont, {:ok, [addr | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp dns(other), do: {:error, {:invalid_dns, other}}
end
