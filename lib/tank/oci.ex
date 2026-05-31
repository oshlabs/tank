defmodule Tank.OCI do
  @moduledoc """
  Interprets a pulled OCI image config against a `Tank.Container` spec to derive
  the workload's run parameters, per the OCI rules:

    * **argv** = `(command || Entrypoint) ++ (args || Cmd)` — the spec's
      `command`/`args` override the image's `Entrypoint`/`Cmd`.
    * **env** = the image `Env`, with the spec's `env` merged over it.
    * **cwd** = `working_dir || image WorkingDir || "/"`.

  The image config is the raw parsed OCI config map (`config["config"]` holds
  the runtime fields), as returned by `Tank.Image.pull/2`.
  """

  alias Tank.Container

  @type run_params :: %{argv: [String.t()], env: [String.t()], cwd: String.t()}

  @doc """
  Derive `%{argv:, env:, cwd:}` for `container` from `image_config`. Returns
  `{:error, :no_command}` if neither the spec nor the image provides a command.
  """
  @spec run_params(Container.t(), map()) :: {:ok, run_params()} | {:error, :no_command}
  def run_params(%Container{} = container, image_config) do
    cfg = image_config |> Map.get("config") |> normalize_map()

    entrypoint = if container.command != [], do: container.command, else: list(cfg["Entrypoint"])
    cmd = if container.args != [], do: container.args, else: list(cfg["Cmd"])

    case entrypoint ++ cmd do
      [] ->
        {:error, :no_command}

      argv ->
        {:ok,
         %{
           argv: argv,
           env: merge_env(list(cfg["Env"]), container.env),
           cwd: cwd(container.working_dir, cfg["WorkingDir"])
         }}
    end
  end

  defp normalize_map(m) when is_map(m), do: m
  defp normalize_map(_), do: %{}

  defp list(l) when is_list(l), do: l
  defp list(_), do: []

  # Image Env is a list of "KEY=VALUE"; the spec env is a %{key => value} map
  # merged over it (spec wins). Result is a "KEY=VALUE" list for Linx.Process.
  defp merge_env(image_env, spec_env) do
    image_env
    |> Enum.reduce(%{}, fn kv, acc ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        [k] -> Map.put(acc, k, "")
      end
    end)
    |> Map.merge(spec_env)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  defp cwd(spec_dir, image_dir) do
    [spec_dir, image_dir]
    |> Enum.find(&(is_binary(&1) and &1 != "")) || "/"
  end
end
