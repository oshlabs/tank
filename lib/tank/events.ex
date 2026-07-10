defmodule Tank.Events do
  @moduledoc """
  Domain events, fanned out to subscribers — the substrate live UIs sit on.

  One duplicate-key Registry with term-shaped topics; delivery is a plain
  message to the subscribing process:

      Tank.Events.subscribe(:pods)
      # …
      receive do
        {:tank_event, :pods, %{name: "web", status: :running}} -> …
      end

  ## Topics

    * `:pods` — pod lifecycle. Payload: `t:pod_event/0`. Desired-state
      changes come from the facade (`:applied` / `:deleted` via
      `Tank.apply/1` / `Tank.delete/1`); observed transitions come from the
      reconciler (`:starting` / `:running` / `:backing_off` / `:terminal`).
    * `{:stats, pod}` — one `t:Tank.Stats.sample/0` per sampling tick for
      that pod (see `Tank.Stats`).

  Same mechanics as `Tank.Logs`' registry (the house pattern for
  subscriptions); `Tank.Logs` keeps its shipped API and may delegate here
  later. Broadcasts are fire-and-forget `Registry.dispatch/3` — a slow
  subscriber cannot block an emitter.
  """

  @registry Tank.Events.Registry

  @type topic :: :pods | {:stats, String.t()}

  @type last_exit ::
          {:exited, non_neg_integer()} | {:signaled, pos_integer()} | {:error, term()}

  @typedoc """
  A `:pods` payload. `:applied`/`:deleted` carry only `name`/`status`/`at`;
  the observed statuses fill in what the reconciler knows at that moment.
  """
  @type pod_event :: %{
          :name => String.t(),
          :status => :applied | :deleted | :starting | :running | :backing_off | :terminal,
          :at => DateTime.t(),
          optional(:host_pid) => pos_integer() | nil,
          optional(:retries) => non_neg_integer(),
          optional(:last_exit) => last_exit() | nil,
          optional(:restart_in_ms) => non_neg_integer() | nil
        }

  @doc false
  def registry, do: @registry

  @doc "Subscribe the calling process to `topic` (idempotent per process)."
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    {:ok, _} = Registry.register(@registry, topic, nil)
    :ok
  end

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc false
  # Deliver `{:tank_event, topic, payload}` to every subscriber of `topic`.
  @spec broadcast(topic(), term()) :: :ok
  def broadcast(topic, payload) do
    Registry.dispatch(@registry, topic, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:tank_event, topic, payload})
    end)
  end
end
