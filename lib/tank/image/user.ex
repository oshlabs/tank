defmodule Tank.Image.User do
  @moduledoc """
  Resolves an image's `User` spec to a numeric `{uid, gid}`.

  A `User` spec -- the image config `User` field, or a container's `:user`
  override -- is `user[:group]`, where each part is a name or a number. Names
  are looked up in the *rootfs's own* `/etc/passwd` and `/etc/group`, the same
  files the container sees, so resolution matches what runs inside.
  """

  @doc """
  Resolves `spec` against `rootfs`'s `/etc/passwd` and `/etc/group`.

  Returns `{:ok, {uid, gid}}`; an empty / `nil` / `"root"` spec is `{0, 0}`. A
  numeric uid with no matching `/etc/passwd` entry takes gid `0`, as Docker
  does. Returns `{:error, {:unknown_user | :unknown_group, name}}` for a name
  absent from the database.
  """
  @spec resolve(Path.t(), String.t() | nil) ::
          {:ok, {non_neg_integer(), non_neg_integer()}}
          | {:error, {:unknown_user | :unknown_group, String.t()}}
  def resolve(_rootfs, spec) when spec in [nil, "", "root"], do: {:ok, {0, 0}}

  def resolve(rootfs, spec) do
    case String.split(spec, ":", parts: 2) do
      [user] ->
        with {:ok, uid, gid} <- resolve_user(rootfs, user), do: {:ok, {uid, gid}}

      [user, group] ->
        with {:ok, uid, _default_gid} <- resolve_user(rootfs, user),
             {:ok, gid} <- resolve_group(rootfs, group) do
          {:ok, {uid, gid}}
        end
    end
  end

  # The user part -> {uid, default_gid}: a number is used as-is (its passwd
  # entry's gid if one exists, else 0); a name must exist in /etc/passwd.
  defp resolve_user(rootfs, user) do
    case numeric(user) do
      {:ok, uid} ->
        gid =
          case passwd(rootfs, &(field(&1, 2) == user)) do
            nil -> 0
            entry -> field_int(entry, 3)
          end

        {:ok, uid, gid}

      :error ->
        case passwd(rootfs, &(field(&1, 0) == user)) do
          nil -> {:error, {:unknown_user, user}}
          entry -> {:ok, field_int(entry, 2), field_int(entry, 3)}
        end
    end
  end

  # The group part -> gid: a number as-is; a name from /etc/group.
  defp resolve_group(rootfs, group) do
    case numeric(group) do
      {:ok, gid} ->
        {:ok, gid}

      :error ->
        case groups(rootfs, &(field(&1, 0) == group)) do
          nil -> {:error, {:unknown_group, group}}
          entry -> {:ok, field_int(entry, 2)}
        end
    end
  end

  # A whole-string non-negative integer, or :error.
  defp numeric(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp passwd(rootfs, pred), do: find(Path.join(rootfs, "etc/passwd"), pred)
  defp groups(rootfs, pred), do: find(Path.join(rootfs, "etc/group"), pred)

  # First colon-separated record (a list of fields) in `file` matching `pred`.
  defp find(file, pred) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, ":"))
        |> Enum.find(pred)

      {:error, _reason} ->
        nil
    end
  end

  defp field(fields, index), do: Enum.at(fields, index)

  # Field `index` of `fields` as an integer, or 0 if missing / non-numeric.
  defp field_int(fields, index) do
    with value when is_binary(value) <- field(fields, index),
         {:ok, n} <- numeric(value) do
      n
    else
      _ -> 0
    end
  end
end
