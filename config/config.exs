import Config

# Compile-time operational defaults. *Desired* state (which pods) is seeded at
# runtime — see config/runtime.exs.

# Whether the application supervisor starts (and owns) a Khepri store. Consumers
# that run their own store, and the test suite, set this to false.
config :tank, start_store?: true

if config_env() == :test do
  import_config "test.exs"
end
