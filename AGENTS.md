This is `tank`, a declarative container orchestrator for the BEAM, built on Linx. Pure Elixir, no native code.

## Boundaries

- **Public Linx API only.** Tank reaches only Linx's public API, never its internals. If Tank needs something Linx doesn't expose, that's a gap in the primitives — **fix it in Linx**, don't reach around the boundary.
- **No native code in Tank.** Anything needing C (syscalls, NIFs, ports) belongs in Linx.

## Code style

- **Keep it simple.** Prefer the most obvious solution that works. Don't add abstraction, configurability, or generality until a second caller needs it.
- **Comment intent, not mechanics.** A comment explains *why*, or names a non-obvious OCI/Khepri/runtime constraint — never restate what the code plainly says.

      # BAD: restates the code
      # write the pod to khepri
      :khepri.put(store, path, pod)

      # GOOD: explains why
      # Seed only if absent: runtime.exs seeds at every boot, but a pod the
      # operator changed at runtime must win over the stale compile-time seed.
      :khepri.create(store, path, pod)

- Keep comments concise — a sentence or two.
- When implementing an existing spec or wire format (OCI image/distribution, a registry API), cite the authoritative source in a comment — name the specific section, and link it where a stable URL exists.
- Match the style, naming, and comment density of the file you are editing.

## Elixir guidelines

- Every module has a `@moduledoc` (`@moduledoc false` for internal modules); every public function has a `@doc`. Document private functions only when intent isn't obvious.
- **Every public function has a `@spec`** — no exceptions. Add `@type`/`@typep` for non-trivial shapes.
- **Model domain data as structs**, not bare maps or loose tuples. Use `@enforce_keys` for required fields, declare a `@type t`, and tag function heads with `%Mod{}`.

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

- **Error handling — shape follows how much context the failure carries:**
  - **Context-rich failure → `%Tank.X.Error{}`** (one struct per subsystem; `defexception` + `message/1`; uniform rendering, plus honest extras only where non-nil). Linx errors that bubble up are passed through as-is — don't re-wrap without adding context.
  - **Context-free condition → a bare atom** (`{:error, :no_such_pod}`), like stdlib `File` / `:gen_tcp`.
  - **Caller input mistake → a tagged tuple** `{:error, {:bad_spec, reason}}`. Do **not** `raise` for these — keep them in the `{:ok, _} | {:error, _}` world for `with` pipelines.
- **Never** nest multiple modules in one file — risks cyclic dependencies and compilation errors.
- Don't use `String.to_atom/1` on external input (image refs, registry data) — memory-leak risk.

## Mix guidelines

- **Always run `mix format` before a git commit.**

## Test guidelines

- **Use `start_supervised!/1`** to start processes — it guarantees cleanup between tests.
- **Avoid** `Process.sleep/1` and `Process.alive?/1`:
  - To wait for a process to finish, use `Process.monitor/1` and assert the DOWN message:

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - To synchronize before the next call, use `_ = :sys.get_state(pid)`.
- Tests needing real namespaces, mounts, or netlink need root — run them via `./sudotest.sh`, tagged `@tag :integration`. Khepri-backed tests start a throwaway store per test with a unique name.
