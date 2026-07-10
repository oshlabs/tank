import Config

# Compile-time operational defaults. *Desired* state (which pods) is seeded at
# runtime — see config/runtime.exs.

# Whether the application supervisor starts (and owns) a Khepri store. Consumers
# that run their own store, and the test suite, set this to false.
config :tank, start_store?: true

# The host-config adapter (uplink + DNS facts). The default reads them from
# config; a consumer swaps in its own. See `Tank.Host`.
config :tank, host: Tank.Host.Static

# Starfish runs embedded: Tank starts the IPAM stack itself (see `Tank.Ipam`),
# attached to Tank's own Khepri store — Starfish's own application supervisor
# must stay off. Pools are declared under `config :tank, :ipam` (runtime.exs).
config :starfish, start?: false

# Reconciler restart backoff: the first restart waits `backoff_base`, doubling
# on repeated rapid failures up to `backoff_cap`. A run that lasts `stable_window`
# resets the doubling back to `backoff_base`. The in-code defaults are
# `backoff_base: :timer.seconds(10)` (matching Kubernetes' CrashLoopBackOff
# floor), `backoff_cap: :timer.minutes(5)`, and `stable_window: :timer.minutes(10)`;
# we lower all three here for quick responsiveness — a 500ms first restart,
# capped at 30s, with the counter resetting after a 30s stable run.
config :tank, :reconciler,
  backoff_base: 500,
  backoff_cap: :timer.seconds(30),
  stable_window: :timer.seconds(30)

if config_env() == :test do
  import_config "test.exs"
end
