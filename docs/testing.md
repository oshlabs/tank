# Testing

How Tank's suite is built, what it covers, and what is deliberately not
covered yet. Companion to `AGENTS.md` (contributor conventions) and
`docs/PLAN.md` (the milestones the gaps map to).

## The two tiers

- **Default suite** (`mix test`) — no root, no network. Spec validation,
  image/pull mechanics, Tank.Net resolution, reconciler logic (stub runtime),
  store semantics.
- **Root suite** (`./sudotest.sh`, tag `:integration`) — real containers:
  namespaces, mounts, cgroups, macvlan, PTYs. The whole thing runs in a
  couple of seconds on a warm cache.

## Hermetic by construction — no Docker Hub, ever

Two pieces of infrastructure, both born from Docker Hub 429s:

- **`Stevedore.Testing`** (lives in stevedore): a real `Stevedore.Server`
  registry on an ephemeral localhost port, serving images built in memory.
  Registry *mechanics* (manifest fetch, digest-verified blobs, extraction,
  caching, multi-arch index → platform resolution) are tested against it over
  real HTTP with zero external network. `Tank.Image.Registry` speaks plain
  HTTP to localhost registries (Docker's own convention), which is what makes
  this work.
- **`Tank.TestImages`** (test/support): the few tests that need a real
  *userland* pull alpine/debian from **ECR's public mirror** (no anonymous
  rate limit) into a persistent cache, offline-first — the network is touched
  only on a cold cache, and never during a test body.

The workhorse image is **deckhand** (`Stevedore.Testing.runnable_image/1`):
stevedore's ~25 KB libc-free container diagnostic. Its three faces map to the
three process shapes the runtime must handle:

| shape | deckhand face | example tests |
|---|---|---|
| long-lived / keepalive | entrypoint REPL + HTTP server (runs until signaled) | bring-up, cgroup limits, reconciler lifecycle, exec target |
| interactive on a PTY | REPL driven via `pty_write`; `cat` applet echoing stdin | attach handoff, `$TERM`, exec REPL-shape |
| run-to-completion | busybox-style applets (`/bin/exit 3`, `/bin/sleep`, `/bin/cat PATH`, `/bin/await-sig`) | exit-code mapping, graceful TERM, exec one-shot shape |

Its HTTP command mirror (`/ifaces`, `/resolve/N`, `/cat/PATH`, `/ping/H`)
lets tests interrogate a pod's **own view of the world from outside** — the
flagship networking e2e is built on this.

**Only two tests use a distro image, both deliberately:** the alpine
rootfs-content probe (a real pivot into a real userland) and the debian
attach flagship (a real bash driven interactively — the M5.5 criterion).

## Coverage map

- **Spec layer**: Pod/Container/Nic/Volume/Mount validation, OCI
  entrypoint/cmd/env merging, `/etc` materialization + DNS fallback chain.
- **Image layer**: pull/caching/content-addressing/offline/index-resolution
  against the local registry, incl. the absolute-symlink tar case.
- **Runtime layer**: rootfs+netns+cgroup bring-up and teardown; volumes
  (managed allocation, host binds, read-only sealing — witnessed from inside
  the pod via `cat` + `/proc/mounts`); every
  workload-exit shape pinned to its supervision reason — KILL →
  `{:shutdown, {:workload_signaled, 9}}`, `exit 3` →
  `{:shutdown, {:workload_exited, 3}}`, graceful TERM (await-sig) →
  `:normal`. The last one is the contract the future drain hook must satisfy.
- **Interactive layer**: attach handoff/detach, death-during-attach, non-tty
  refusal, default TERM; exec in both shapes, asserting *namespace
  membership* (port-taken degradation + lo-only netns — the assertions that
  caught linx's enter/2 bug, which `cat /proc/1/comm` alone never could).
- **Network layer**: macvlan mechanics, `{:ipam, subnet}` → real addressed
  interface, and the flagship e2e: a pod witnesses its IPAM address,
  shim-nameserver resolv.conf, name resolution through the embedded DNS, and
  pod→shim ICMP — reached host→pod through the shim.
- **Orchestration**: reconciler policy/backoff (stub) + apply/delete against
  real containers.

## Spec'd but not actuated (implementation gaps, not test gaps)

The declarative surface is deliberately ahead of the runtime; the suite tests
the *refusals* honestly (`{:nic_mode_unsupported, _}`, the `:dhcp` warning).

| feature | spec layer | runtime | tracked |
|---|---|---|---|
| multi-container pods | ✅ | runs first container only | PLAN M7 |
| ~~volumes / mounts~~ | ✅ | **actuated 2026-07-10** — managed dirs under `data_dir/volumes`, host binds, ro sealing; e2e witnesses rw/ro from inside via `/proc/mounts` | done |
| log capture | — | stdio → `/dev/null` | PLAN (later) |
| `:dhcp` NICs | ✅ | warns, leaves NIC bare | wire Starfish's DHCP client |
| `:bridge` / `:ipvlan` | ✅ modelled | hard error | `docs/networking.md` [modelled] |
| `:routed` + firewalling | — | — | `docs/networking.md` [future] |
