defmodule Tank.Store.Web do
  @moduledoc """
  The web layer's persistence, hard-rooted at `[:tank_web]` in the shared
  Khepri store.

  tank_web lives inside the tank OTP app, but its state stays in its own
  subtree behind this module — the greppable boundary: all web persistence
  goes through `Tank.Store.Web`, and web code physically cannot reach
  `[:tank, :pods]` through it. Values are plain terms; typed structs
  (users, sessions — the login milestone) are the web layer's concern.

      Tank.Store.Web.put(["users", id], %{name: "leon", hash: …})
      Tank.Store.Web.get(["users", id])
      Tank.Store.Web.list(["users"])
      Tank.Store.Web.delete(["sessions", token])

  Reads go straight to Khepri (rare, per-request at most). If session-token
  lookups ever show up in latency, the upgrade path is an ETS projection
  like the pods one — not caching here.
  """

  @root [:tank_web]

  @type path :: [String.t()]

  @spec put(path(), term()) :: :ok | {:error, term()}
  def put(path, value) when is_list(path) and path != [],
    do: Tank.Store.put_at(@root ++ path, value)

  @spec get(path()) :: {:ok, term()} | {:error, :not_found}
  def get(path) when is_list(path) and path != [], do: Tank.Store.get_at(@root ++ path)

  @doc "Delete a node (and its subtree). A missing node is `:ok`, like `delete_pod`."
  @spec delete(path()) :: :ok | {:error, term()}
  def delete(path) when is_list(path) and path != [], do: Tank.Store.delete_at(@root ++ path)

  @doc "Direct children of `path` as `{leaf_name, value}` pairs."
  @spec list(path()) :: {:ok, [{String.t(), term()}]} | {:error, term()}
  def list(path) when is_list(path), do: Tank.Store.children_at(@root ++ path)
end
