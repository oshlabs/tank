defmodule Tank.Host do
  @moduledoc """
  The host-config seam: how Tank reads the *host's* network facts without owning
  them — the uplink a macvlan attaches to, and the DNS servers a container
  inherits.

  Tank must share these without dragging in any host-networking dependency (it
  also runs on a plain Linux laptop), so `Tank.Host` is a **behaviour**: an adapter
  contract. The adapter is chosen by config and reached through this module's
  facade — callers say `Tank.Host.uplink()` and never name the adapter:

      config :tank, host: Tank.Host.Static   # the default

  Adapters:

    * `Tank.Host.Static` — shipped here, the v1 default: uplink + DNS straight
      from config. Runs anywhere.
    * A **consumer-provided adapter** — lives in the consumer, never in Tank's
      deps: reads the host's own network manager. *(later)*
    * `Tank.Host.Linx` — auto-detect uplink + DNS from rtnetlink and
      `/etc/resolv.conf`; a zero-config laptop default. *(later)*

  The contract is intentionally just what Tank core consumes today: the uplink
  (resolving a NIC's `parent: :auto`) and the DNS list (the pod's
  `/etc/resolv.conf` when it declares no `dns:`). It will grow host IP facts and
  change-notifications when an adapter that has them needs them.
  """

  @doc "The uplink interface name a macvlan should attach to (`parent: :auto`)."
  @callback uplink() :: {:ok, String.t()} | {:error, term()}

  @doc "The host's DNS servers, as address strings (may be empty)."
  @callback dns() :: [String.t()]

  @doc "Resolve the host uplink via the configured adapter."
  @spec uplink() :: {:ok, String.t()} | {:error, term()}
  def uplink, do: adapter().uplink()

  @doc "The host DNS servers via the configured adapter."
  @spec dns() :: [String.t()]
  def dns, do: adapter().dns()

  @doc "The configured host adapter module (default `Tank.Host.Static`)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:tank, :host, Tank.Host.Static)
end
