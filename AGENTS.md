This is `tank`, an opinionated single-node (growing to multi-node) declarative
container orchestrator for the BEAM, built on Linx and designed to be embedded
in an embedded device OS. The code is pure Elixir. See `docs/PLAN.md`
for the architecture and route.

## What Tank is, in one breath

You describe the containers that must run (with their network, resources, and
restart policy) as Elixir data; the desired state lives in **Khepri**; a
reconcile loop converges the device toward it and keeps it there across drift,
crashes, and reboots. Containers run from real OCI images on Linx's kernel
primitives. Opinionated: macvlan networking, no pluggable CNI, no YAML.

## Boundaries — read before adding code

- **Public Linx API only.** Tank depends on Linx via a *path* dependency as a
  separate OTP application, so it reaches only Linx's public API, never its
  internals. This is structural, not discipline. If Tank needs something Linx
  doesn't expose, **that is a real gap in the primitives — fix it in Linx**, do
  not reach around the boundary. This is Tank's charter as Linx's acceptance
  test.
- **No native code in Tank.** Anything needing C (syscalls, NIFs, ports) belongs
  in Linx. Tank is Elixir all the way down.
- **Mechanism vs policy.** Linx is mechanism. Tank is policy: *which* containers,
  *which* network, *what* should be running. Keep the seam crisp.
- **Tank stays liftable.** It must remain a `git mv` + one dependency-line change
  away from its own repository — no hidden coupling to the surrounding Linx tree.

## Code style

- **Keep it simple.** Prefer the most obvious solution that works. Don't add
  abstraction, configurability, or generality until a second caller needs it.
  Tank is opinionated *on purpose* — resist plugin surfaces and knobs.
- **Comment intent, not mechanics.** A comment explains *why*, or names a
  non-obvious kernel/OCI/Khepri constraint — never restate what the code says.

      # BAD: restates the code
      # write the pod to khepri
      :khepri.put(store, path, pod)

      # GOOD: explains why
      # Seed only if absent: runtime.exs seeds at every boot, but a pod the
      # operator changed at runtime must win over the stale compile-time seed.
      :khepri.create(store, path, pod)

- Keep comments concise — a sentence or two.
- When implementing a spec or wire format (OCI image/distribution, DHCP, a
  registry API), cite the authoritative source in a comment — name the section
  and link a stable URL. A reader should be able to check it without guessing.
- Match the style, naming, and comment density of the file you are editing.

## Elixir guidelines

- Every module has a `@moduledoc` (`@moduledoc false` for internal modules);
  every public function has a `@doc`. Document private functions only when
  intent isn't obvious.
- **Every public function has a `@spec`** — no exceptions. Add `@type`/`@typep`
  for non-trivial shapes.
- **Model domain data as structs**, not bare maps or loose tuples. Use
  `@enforce_keys` for required fields, declare a `@type t`, and tag function
  heads with `%Mod{}`. The desired-state model (`Tank.Pod`, `Tank.Container`,
  `Tank.Pod.Network`, `Tank.Volume`) is structs, end to end.

      defmodule Tank.Pod do
        @enforce_keys [:name, :containers]
        defstruct [:name, :containers, :network, :restart, volumes: []]

        @type t :: %__MODULE__{
                name: String.t(),
                containers: [Tank.Container.t(), ...],
                network: Tank.Pod.Network.t() | nil,
                restart: :always | :on_failure | :never,
                volumes: [Tank.Volume.t()]
              }
      end

- **Errors are structs, by context.** Mirror the Linx three-lane model:
  1. **Context-rich failure → `%Tank.X.Error{}`**, returned as
     `{:error, %Tank.X.Error{}}`. Each such struct `defexception`s and
     implements `message/1`, so `Exception.message/1` renders any Tank error
     uniformly. Never pad a struct with a forever-`nil` field. Linx errors that
     bubble up are passed through as-is (a `%Linx.Mount.Error{}` is already a
     good error) — don't re-wrap them without adding context.
  2. **Context-free condition → a bare atom**: `{:error, :no_such_pod}`.
  3. **Caller-side validation → a tagged tuple**: `{:error, {:bad_spec, reason}}`.
     Don't raise `ArgumentError` — Tank's inputs are dynamic runtime data; stay
     in the `{:ok, _} | {:error, _}` world for `with` pipelines.
- Lists **do not support index access** (`list[0]`). Use `Enum.at`, pattern
  matching, or `List`.
- Variables are immutable but rebindable. Bind the result of an `if`/`case`/
  `cond` block; you cannot rebind inside it.
- **Never** nest multiple modules in one file (cyclic-dependency and compile
  risk).
- **Never** use map-access syntax (`struct[:field]`) on structs — use
  `struct.field`.
- Don't use `String.to_atom/1` on external input (image refs, registry data,
  Khepri values) — memory-leak risk.
- Predicate names end in `?`, not `is_` — reserve `is_` for guards.
- OTP primitives (`DynamicSupervisor`, `Registry`) need names in the child spec.
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure,
  usually `timeout: :infinity`.

## Reconcile philosophy

- **Level-triggered: events are hints, resync is truth.** Khepri deltas wake the
  loop sooner; correctness comes from periodically diffing the full desired set
  against observed reality. Never rely on having seen every event.
- **Idempotent and self-healing.** Applying the same desired state twice is a
  no-op; drift (a killed container, a flushed route) is corrected on the next
  pass. Reuse the `Linx.Reconcile` template and the per-subsystem reconcilers
  (`Rtnl.Reconcile`, `Cgroup.Reconcile`) rather than reinventing them.
- **Lifetime = ownership.** A pod's network and cgroup are born and die with it;
  a restart rebuilds from scratch.

## Khepri discipline

- Tank owns the **`[:tank, …]`** subtree and nothing else. Do not read or write
  another system's subtree (e.g. `[:other_app, …]`).
- Tank **uses** a store; it does not own the store's lifecycle or cluster
  membership (the consumer's job). Take the store name as configuration; start a
  default store only for standalone/test use (`Tank.Store`).
- Reads on the hot path go through the **ETS projection**, not direct Raft
  queries. Writes are idempotent; use transactions for atomic multi-key updates.
- Treat the store as eventually-clustered: never assume single-node semantics
  that would break with peers (e.g. don't stash node-local PIDs in Khepri).

## Mix guidelines

- Check task docs/options with `mix help task_name`.
- Debug failures with `mix test test/my_test.exs` or `mix test --failed`.
- `mix deps.clean --all` is almost never needed — avoid it.
- **Always run `mix format` before a git commit.**

## Test guidelines

- **Use `start_supervised!/1`** to start processes — it guarantees cleanup
  between tests.
- **Avoid** `Process.sleep/1` and `Process.alive?/1`:
  - To wait for a process to finish: `Process.monitor/1` + assert the `:DOWN`.
  - To synchronize before the next call: `_ = :sys.get_state(pid)`.
- Tests that need real namespaces, mounts, or netlink need root — run them via
  `./sudotest.sh` (`sudo mix test --include integration`), as in Linx. Tag them
  `@tag :integration`. Keep a fast, root-free unit suite (struct validation,
  image-ref parsing, diff logic) that runs under plain `mix test`.
- For Khepri-backed tests, start an in-memory/throwaway store per test with a
  unique name and tear it down — never share a persistent store across tests.
