defmodule Tank.Container do
  @moduledoc """
  A container's desired state inside a pod.

  The OCI image config supplies defaults; these fields override it (see
  `Tank.OCI`): `command` overrides the image `Entrypoint` and `args` overrides
  `Cmd` — and as in Docker, setting `command` resets `Cmd`. `env` is merged over
  the image `Env`; `working_dir` and `user` override the image's, with `user`
  resolved against the *rootfs's* `/etc/passwd` and `/etc/group`.

    * `image` — an OCI reference (`"nginx:1.27"`) or the `{:rootfs, path}` escape
      hatch (an already-assembled rootfs directory).
    * `mounts` — `Tank.Mount`s, each naming a pod-level `Tank.Volume`.
    * `limits` — a map of cgroup limits: `:memory` (bytes), `:pids`, `:cpu`
      (`{quota_us, period_us}`).
    * `tty` — when `true`, the container's main process runs on a PTY (rather
      than captured stdout/stderr streams), so `Tank.attach/1` can take over
      its terminal; its output reaches the pod log as the merged `:tty`
      stream. Use it for a container that *is* an interactive shell.
      Default `false`.

  > #### Not the runtime {: .info}
  > This is the *desired-state struct*. The supervised GenServer that brings a
  > container to life is `Tank.Runtime`.
  """

  alias Tank.{Mount, Validate}

  @type image :: String.t() | {:rootfs, Path.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          image: image(),
          command: [String.t()],
          args: [String.t()],
          env: %{optional(String.t()) => String.t()},
          working_dir: String.t() | nil,
          user: String.t() | nil,
          mounts: [Mount.t()],
          limits: map(),
          tty: boolean()
        }

  @enforce_keys [:name, :image]
  defstruct name: nil,
            image: nil,
            command: [],
            args: [],
            env: %{},
            working_dir: nil,
            user: nil,
            mounts: [],
            limits: %{},
            tty: false

  @keys [:name, :image, :command, :args, :env, :working_dir, :user, :mounts, :limits, :tty]

  @doc "Build a validated container from a map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:__struct__)

    with :ok <- Validate.keys(attrs, @keys),
         {:ok, name} <- Validate.name(attrs[:name]),
         {:ok, image} <- image(attrs[:image]),
         {:ok, command} <- Validate.strings(Map.get(attrs, :command, [])),
         {:ok, args} <- Validate.strings(Map.get(attrs, :args, [])),
         {:ok, env} <- env(Map.get(attrs, :env, %{})),
         {:ok, working_dir} <- working_dir(Map.get(attrs, :working_dir)),
         {:ok, user} <- user(Map.get(attrs, :user)),
         {:ok, mounts} <- Validate.build_list(Map.get(attrs, :mounts, []), Mount),
         :ok <- Validate.unique(mounts, & &1.path),
         {:ok, limits} <- limits(Map.get(attrs, :limits, %{})),
         {:ok, tty} <- Validate.one_of(Map.get(attrs, :tty, false), [true, false]) do
      {:ok,
       %__MODULE__{
         name: name,
         image: image,
         command: command,
         args: args,
         env: env,
         working_dir: working_dir,
         user: user,
         mounts: mounts,
         limits: limits,
         tty: tty
       }}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs), do: Validate.bang(__MODULE__, attrs)

  defp image(ref) when is_binary(ref) and ref != "", do: {:ok, ref}

  defp image({:rootfs, path}) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, {:rootfs, path}},
      else: {:error, {:rootfs_path_not_absolute, path}}
  end

  defp image(other), do: {:error, {:invalid_image, other}}

  defp env(map) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, map},
      else: {:error, {:invalid_env, map}}
  end

  defp env(other), do: {:error, {:invalid_env, other}}

  defp working_dir(nil), do: {:ok, nil}

  defp working_dir(p) when is_binary(p) do
    if Path.type(p) == :absolute, do: {:ok, p}, else: {:error, {:working_dir_not_absolute, p}}
  end

  defp working_dir(other), do: {:error, {:invalid_working_dir, other}}

  defp user(nil), do: {:ok, nil}
  defp user(u) when is_binary(u) and u != "", do: {:ok, u}
  defp user(other), do: {:error, {:invalid_user, other}}

  defp limits(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case limit(key, value) do
        :ok -> {:cont, {:ok, Map.put(acc, key, value)}}
        err -> {:halt, err}
      end
    end)
  end

  defp limits(other), do: {:error, {:invalid_limits, other}}

  defp limit(:memory, v) when is_integer(v) and v > 0, do: :ok
  defp limit(:pids, v) when is_integer(v) and v > 0, do: :ok

  defp limit(:cpu, {quota, period})
       when is_integer(quota) and quota > 0 and is_integer(period) and period > 0,
       do: :ok

  defp limit(key, value), do: {:error, {:invalid_limit, key, value}}
end
