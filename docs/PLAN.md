# Tank — plan

Tank is an opinionated, single-node (growing to multi-node) **declarative
container orchestrator** for the BEAM, built entirely on Linx's public API and
designed to be embedded in **TankOS**, a Nerves device OS. You describe the
containers that must run — with their network, resources, and restart policy —
as Elixir data; Tank reconciles the device toward that desired state and keeps
it there across drift, crashes, and reboots.

This document is the *why* and the *route*. It is a living plan: as milestones
land, the milestone section is updated, and design decisions that get settled
move into the relevant moduledocs.

## The one-paragraph pitch

Think of how Kubernetes defines pods that must run — but single-node, no API
server, no YAML, no pluggable CNI, and expressed in idiomatic Elixir. The
desired state lives in **Khepri** (a Raft-backed tree store), seeded at boot and
mutable at runtime. A reconcile loop — built on the `Linx.Reconcile` machinery —
converges the node's reality toward it. Containers run from real OCI/Docker
images on Linx's kernel primitives. Tank is deliberately *opinionated*: it makes
the embedded-device choices (macvlan networking, root-remap hardening, a single
consistent state tree) so the consumer doesn't assemble a runtime from parts.

## Lineage: Silo → Linx → Tank

- **Silo** (`~/src/silo`) was the monolithic ancestor: it bundled the kernel
  primitives (`Silo.Netlink`, the `silo-init` port, `Silo.Cgroup`) *and* an OCI
  image puller *and* the container orchestration in one app.
- **Linx** extracted and generalized the primitive layer: `Linx.Process`
  (≈ `silo-init`), `Linx.Netlink.Rtnl` (≈ `Silo.Netlink`), `Linx.Cgroup`,
  `Linx.Mount`, `Linx.User`, `Linx.Seccomp`, `Linx.Capabilities`, `Linx.Sysctl`,
  plus the new declarative `Linx.Reconcile` machinery.
- **Tank** is the orchestrator that `Silo.Container` / `Silo.run` once were —
  rebuilt cleanly *on top of* Linx, declaratively, with reconciliation, and with
  a persistent state store from day one.

Tank reaches **only Linx's public API** (a path dependency now, a hex dependency
once lifted). If Tank ever needs something Linx doesn't expose, that is a real
gap in the primitives — surfaced here, fixed in Linx. This is Tank's standing
charter and its value as Linx's acceptance test.

### What lifts from Silo essentially unchanged

`Silo.Image`, `Silo.Image.Registry`, `Silo.Image.Tar`, `Silo.Image.User` are
**pure Elixir** — they depend only on `req`, `:crypto`, and `:zlib`; no native
code, no netlink. They move into `Tank.Image.*` with a rename and a `req`
dependency. They already cover: anonymous bearer-token auth from the
`WWW-Authenticate` challenge, multi-arch index/manifest selection by host arch,
blob fetch + sha256 verification, a content-addressed cache, a hand-rolled
ustar/GNU/PAX tar reader (because `:erl_tar` refuses the absolute symlinks a
rootfs needs), OCI whiteout stacking, and `User` resolution against the rootfs's
own `/etc/passwd`/`/etc/group`.

## Architecture

A small set of composable modules, each with one job.

| Module | Role |
| --- | --- |
| `Tank.Image.*` | Pull + assemble an OCI/Docker image into a rootfs (lifted from Silo). |
| `Tank.Pod`, `Tank.Container`, `Tank.Pod.Network`, `Tank.Nic`, `Tank.Volume` | The desired-state structs — what *should* run. |
| `Tank.Store` | The Khepri seam: own the `[:tank, …]` subtree, project it to ETS, BYO-store-or-default. |
| `Tank.Runtime` (a.k.a. `Tank.Pod.Runner`) | The actuator: turn one pod spec into running reality on Linx. |
| `Tank.Reconciler` | The control loop: converge observed reality toward the desired set; restart with backoff. |
| `Tank.Host` | The host-config seam (a behaviour): uplink, DNS, host IP facts. `Tank.Host.Static` default; VintageNet/Linx adapters plug in. |
| `Tank` | Top-level API (`pod/2`, `apply/1`, `delete/1`) + the supervision tree. |

The seam between **mechanism** (Linx) and **policy** (Tank) is strict; the seam
between **desired state** (`Tank.Pod` structs in Khepri) and **actuation**
(`Tank.Runtime` driving Linx) is the reconcile boundary.

## The desired-state model

Borrow PodSpec's *field names* where they read well; trim hard to the
single-node subset; drop everything scheduler- or cluster-coupled (affinity,
ConfigMap/Secret indirection, Services, QoS, probes-as-mandatory).

```elixir
%Tank.Pod{
  name: "web",                       # unique key; the Khepri path leaf
  containers: [%Tank.Container{}],   # 1+, sharing one network namespace
  network: %Tank.Pod.Network{},      # pod-level (the netns is the pod)
  volumes: [%Tank.Volume{}],         # pod-level; mounted into containers
  restart: :always                   # :always | :on_failure | :never
}

%Tank.Container{
  name: "app",
  image: "nginx:1.27",               # OCI ref; or {:rootfs, path} escape hatch
  command: ["/usr/sbin/nginx"],      # overrides the image Entrypoint
  args: ["-g", "daemon off;"],       # overrides the image Cmd
  env: %{"TZ" => "UTC"},             # merged over the image Env
  working_dir: "/",                  # overrides the image WorkingDir
  user: "nginx",                     # name or uid[:gid], resolved in the rootfs
  mounts: [%{volume: "data", path: "/var/lib/data", read_only: false}],
  limits: %{memory: 256 <<< 20, pids: 100, cpu: {50_000, 100_000}}
}

# The pod is one netns, but a netns holds any number of interfaces:
%Tank.Pod.Network{
  nics: [
    %Tank.Nic{name: "eth0", mode: :macvlan, parent: "eth0",
              ip: {"10.0.0.5", 24}, gateway: "10.0.0.1"},
    %Tank.Nic{name: "eth1", mode: :macvlan, parent: "eth1",
              ip: {"192.168.5.5", 24}}
  ],
  dns: ["10.0.0.1"]      # pod-level: one /etc/resolv.conf per netns
}
# loopback is always raised. `mode:` is per-NIC: :macvlan (v1) | :bridge/:ipvlan
# (later). `parent:` is the uplink (a shared host fact; :auto resolves via
# Tank.Host). `ip:` is {addr, prefix} static (v1); :dhcp comes later.
#
# `network:` may also be the simple whole-netns atoms :host (share the host's
# network namespace) or :none (isolated netns, loopback only).
```

**Image config → run parameters** follows the OCI spec: `args = command ||
Entrypoint`, then `++ (args || Cmd)`; `env` is the image `Env` with the pod's
`env` merged over it; `user` resolves against the *rootfs's* `/etc/passwd` and
`/etc/group`. (See `Tank.Image` for the citations.)

**Restart + backoff** is owned by the reconciler, K8s-style and configurable:
`delay = min(10s · 2ⁿ, 300s)`, reset after a stable-run window (~10 min). We do
not lean on systemd — Nerves has none.

## State: Khepri from day one

Khepri is the **desired-state store** — Tank's etcd. It is single-node now (a
one-member Raft cluster) and grows into a real cluster later without changing
shape; that is the whole reason to adopt it early rather than a flat file.

**Who owns the store.** Tank is a *library*, so it never owns the store's
lifecycle or cluster membership — those are application/host concerns:

- **TankOS owns the store.** It starts Khepri, points Ra's data directory at the
  writable data partition (flash-wear aware), manages cluster join/leave, and
  hosts its own `[:tankos, …]` subtrees (e.g. host network config).
- **Tank owns `[:tank, …]`.** It reads/writes/watches its subtree and takes the
  *store name* as configuration. For standalone use (tests, dev, Tank without
  TankOS) `Tank.Store` starts a default store if none is supplied — the
  "bring-your-own-or-I'll-boot-a-default" pattern.

```
[:tank, :pods, "web"]   -> serialized %Tank.Pod{}   (the desired pod)
[:tank, :pods, "db"]    -> serialized %Tank.Pod{}
```

**Khepri is the source of truth.** `config/runtime.exs` only *bootstraps* the
subtree: on a fresh device Tank writes the configured pods *create-if-absent*,
so the boot seed never clobbers state changed at runtime, and runtime changes
persist across reboots. Config is a starting point, not a live mirror — removing
a pod is `Tank.delete/1`, not deleting it from config. (A later `managed_by`
ownership tag — the same three-way `last_applied` trick Linx's reconciler uses —
could let config-owned pods reconcile from config each boot while runtime-owned
pods persist; deferred.)

The runtime API (`Tank.apply/1` / `Tank.delete/1`) writes the `[:tank, :pods, …]`
subtree thereafter, and **every write auto-propagates to reality**: it updates
the projection, which wakes the reconciler, which diffs desired against running
and starts/stops/restarts pods to match. You never imperatively start a
container — you state intent in Khepri and the loop converges. This is exactly
the Kubernetes shape: writes land in etcd, the kubelet watches and reconciles —
Tank collapses the two, Khepri *is* etcd and `Tank.Reconciler` *is* the kubelet.

The reconciler reads desired state through a **`khepri_projection`** mirroring
`[:tank, :pods, **]` into ETS: fast local reads, change notifications to wake the
loop, and a full projection read for the level-triggered resync.

## Operational config — where Tank keeps its stuff

Distinct from desired state ("what pods"), operational config is "where Tank
keeps its stuff" — plain Application env / `runtime.exs`:

    config :tank, data_dir: "/var/lib/tank"   # images/, volumes/, run/ live here

On a laptop this defaults to a user cache dir (e.g. `~/.cache/tank`). The
Khepri/Ra data dir specifically is owned by the *consumer* (TankOS sets it
on-device, flash-wear aware); standalone Tank's default store gets a dir under
`data_dir`.

**Volume vs mount.** A `%Tank.Container{}` mount `path` is the container-side
mountpoint — always absolute (it is a path inside the rootfs). Its *source* is a
pod-level `%Tank.Volume{}`: either a **named volume** (Tank allocates
`<data_dir>/volumes/<name>` — relative to the configured root, Tank-managed) or
an explicit **host path** (an absolute host directory, bind-mounted — the escape
hatch).

## The reconcile loop

Level-triggered: events are hints, resync is truth. On a timer (and on Khepri
projection deltas, debounced) the reconciler diffs the **desired** pod set
against the **observed** running set and actuates:

- desired ∧ ¬running → start a `Tank.Runtime` for the pod
- running ∧ ¬desired → stop and remove it
- running ∧ desired-but-changed → reconcile in place where cheap (e.g. network,
  limits), or restart the pod
- crashed → restart per policy, with exponential backoff

This composes the `Linx.Reconcile` template directly; per-pod *network* and
*cgroup* reconciliation reuse `Linx.Netlink.Rtnl.Reconcile` and
`Linx.Cgroup.Reconcile` inside each runner.

## The hard part: running a real OCI rootfs on Linx (the acceptance test)

`silo-init` did the whole container filesystem setup *inside the child*: mount a
fresh `/dev` (bind-mounting host device nodes, since `mknod` is barred in a user
namespace), `/proc`, `/sys`; `pivot_root` into the image rootfs; drop user;
`execve`. **`Linx.Process` deliberately does none of this** — it clones into
namespaces, parks at the `:ready` checkpoint, and `execve`s the workload
directly. The Linx model is: `Linx.Process` makes the namespaces; *other* Linx
modules configure the child in the checkpoint window, addressing it by
`{:pid, host_pid}` — `Linx.Mount` (`pivot_root` + the `:in` cross-namespace
option), `Linx.User`, `Linx.Capabilities`, `Linx.Seccomp`.

So Tank's rootfs path must drive `Linx.Mount` from the host (or from the child)
to build the container's filesystem at the checkpoint. **Whether the current
Linx mount/user primitives are sufficient to reproduce silo-init's setup is
genuinely uncertain** and must be proven by a spike before the orchestration is
built on it. Known concerns to resolve:

- **`/proc` from the right PID namespace.** A `proc` mount reflects the PID
  namespace of the process that mounts it. To give the container a `/proc` that
  shows *its* PIDs, the mount must be performed by a process in the container's
  PID namespace — which the host-side checkpoint helper is not. Does this force
  a child-side setup step, or a setns into both mount+pid?
- **`pivot_root` via a setns'd helper vs in-child.** `pivot_root` acts on the
  caller's mount namespace; the post-pivot process must `chdir("/")` and the
  workload must exec with the new root. Can this be driven entirely from the
  checkpoint window, or does `Linx.Process` need a "run rootfs setup in the
  child before exec" capability it does not have today?
- **The standard `/dev` + bind-mounted device nodes, `/dev/pts`, `/dev/shm`,
  `/sys`** — reproducing silo-init's device setup through `Linx.Mount`.
- **`userns` (root-remap) + idmapped rootfs** — Silo's hardening (container ids
  remapped onto an unprivileged host range, rootfs exposed via an idmapped
  mount). Does Linx expose the idmapped-mount machinery, or is that a gap?

This phase is the substance of Tank's charter: expect it to surface real gaps in
Linx, and fix them there, not paper over them in Tank.

**Resolved (M2): host-side setup is the pattern, and it holds.** The spike
proved the whole rootfs can be built from the host in the checkpoint window —
`spawn` → receive `:ready` (which carries the workload's **host pid**) →
configure everything from Elixir via the public `Linx.*` verbs → `proceed`. The
deliberate consequence is a *thin, general C port*: `linx_process` knows only
`clone`/`setns`/`fork`/`execve` + the checkpoint relay, and zero rootfs policy.
All policy (proc, dev, sys, pivot, network, cgroups, uid maps) lives in testable,
composable Elixir, the same verbs every other caller uses. This minimises the
privileged/unsafe surface and gives every concern the same lifecycle shape.

The two open questions above are answered:

- **`/proc` from the right pidns** needs no child-side setup step. `Linx.Mount`,
  when mounting `proc` with `in: {:pid, host_pid}`, enters the target *pid*
  namespace and `fork()`s a child to do the mount, so procfs binds to the
  container's pidns. This is the one resource that fights host-side mounting
  (procfs binds to the *mounting task's* pidns), and the fork is a small,
  contained C mechanism that keeps the host-side pattern **universal** rather
  than carving out an exception for proc.
- **`pivot_root`** is driven entirely from the checkpoint window via
  `Linx.Mount.pivot_root` with `:in`; the workload then gets a valid cwd via
  `Linx.Process`'s `:cwd` (chdir before execve). No "run setup in the child"
  capability is needed.

Two disciplines this pattern demands, both now standing rules:

- **rec-private before any in-container mount.** A child's mount ns is a *shared
  peer* of the host's, so a mount into it propagates back and can break the host
  (`mount("", "/", "", flags: [:private, :rec], in: {:pid, host_pid})` first).
- **address the container by its host pid**, the value `:ready` now reports
  (its in-namespace pid is 1 in a fresh pidns → resolves to systemd).

The one sharp edge of the approach: the forked proc-mount child must stay
**async-signal-safe** (only `mount`/`write`/`_exit` — no malloc/erl_nif), or it
deadlocks against a BEAM-held lock. It is the single place where host-side setup
pays for itself in C; everything else is plain Elixir. Guard that function.

## Networking

**macvlan on the uplink** is the v1 default and the opinionated choice: a
container interface gets its own MAC and a real LAN IP — **static in v1**, its
own DHCP later — with no bridge, no NAT, no nftables, and the link dies with the
netns, so there is no allocation or teardown state to manage. The container is a
first-class host on the LAN, the natural embedded-device model. All of it is
`Linx.Netlink.Rtnl`: create each macvlan on its host uplink, move it into the
pod's netns under its `%Tank.Nic{}` name, address it and add routes — driven in
the checkpoint window, reusing `Rtnl.Reconcile`. A pod's netns can hold several
nics (e.g. one per uplink); loopback is always raised; DNS is pod-level.

Each `%Tank.Nic{}`'s `mode` is the extensibility seam: **bridge+NAT** (many pods
behind a host bridge with port publishing, via `Linx.Netfilter`) slots in later
as another mode without reshaping the API. `:host` (share the host network) and
`:none` (isolated netns, loopback only) are the whole-netns shortcuts. A
**DHCP-client-in-netns** (for images that cannot address themselves) is a later
Linx-side addition.

> Note: macvlan is commonly refused on Wi-Fi uplinks by the AP; on Wi-Fi-only
> devices the bridge mode (later) or `:host` is the path. Worth validating per
> target.

## Host-config sharing

Tank must *share certain aspects* of host networking without owning them — and
without dragging in any Nerves dependency, because Tank must also run standalone
on a plain Linux laptop. So `Tank.Host` is a **behaviour** (an adapter
contract), and **Tank core has zero compile-time dependency on VintageNet or
anything Nerves**. The contract exposes:

- the **uplink interface** name (the macvlan parent; resolves `parent: :auto`),
- the host **DNS servers** (for the container's `/etc/resolv.conf`),
- host **IP/connection facts** (snapshot + change notifications).

Adapters:

- **`Tank.Host.Static`** — shipped in Tank, the v1 default: uplink + DNS read
  straight from config. Runs anywhere, laptop included.
- **`Tank.Host.VintageNet`** — lives in **TankOS** (or a tiny optional sibling
  package), never in Tank's deps. Reads VintageNet's PropertyTable
  (`["interface", ifname, "addresses"]`, `["name_servers"]`,
  `["interface", ifname, "connection"]`) and subscribes to its
  `{VintageNet, property, old, new, meta}` events.
- **`Tank.Host.Linx`** *(later)* — auto-detect uplink + DNS from rtnetlink and
  `/etc/resolv.conf`; a zero-config Linux/laptop default.

All behind the same behaviour, so nothing on the Tank side changes when the
consumer swaps adapters. Tank never configures the host's uplink; it only reads
it and builds container networking off it.

## TankOS (the consumer, out of tree)

TankOS is a separate Nerves application that depends on Tank. Its
responsibilities, kept out of the Tank library:

- start and own the **Khepri store** (Ra data dir on the writable partition,
  cluster membership),
- configure **host networking** (VintageNet today),
- seed `[:tank, :pods, …]` from device config and expose a management surface,
- run Tank in its supervision tree.

Tank stays liftable into its own repository: `git mv tank ../tank` plus flipping
`{:linx, path: ".."}` to `{:linx, "~> x.y"}`.

**Standalone, off Nerves.** Tank is a first-class standalone app — the primary
dev loop is a plain Linux laptop, not a device. There it starts its own default
Khepri store, uses `Tank.Host.Static`, and runs as root for namespaces / mounts
/ netlink via the repo's `./sudorun.sh` (root `iex -S mix`) and `./sudotest.sh`
(root test run), mirroring Linx's scripts.

## Milestones

Each milestone is a commit-and-push checkpoint. Earlier milestones de-risk the
foundation (image pull, the rootfs spike) before the declarative layer is built
on top.

- **M0 — Plan + AGENTS.md.** This document and the agent guide. *(done)*
- **M1 — Lift the image puller.** `Tank.Image{,.Registry,.Tar,.User}` from Silo;
  pure Elixir; pull + assemble an OCI rootfs; cache; tests. Adds the `req`
  dependency.
- **M2 — Rootfs container spike (the acceptance test).** Run a real OCI image on
  Linx — rootfs setup, standard mounts, `pivot_root`, user drop — via
  `Linx.Mount`/`Linx.User` in the checkpoint window. Surface and fix Linx gaps.
  *(done — ran a real alpine container; the gaps it surfaced are fixed in Linx:
  pidns-aware proc mount, bind `create:`, `Linx.Process` `:cwd`, and the
  `:ready` message now reports the host pid.)*
- **M3 — Desired-state model + `Tank.Store`.** The `Tank.Pod`/`Container`/
  `Network`/`Volume` structs; the Khepri seam (BYO-or-default store, the
  `[:tank, …]` subtree, the ETS projection); seeding from `runtime.exs`. Adds
  the `khepri` dependency. *(done — `Tank.Pod` & friends with validating
  `new/1`; `Tank.Store` (CRUD + projection); `Tank.apply/1`/`delete/1`/`list/0`;
  `Tank.Application` seeds create-if-absent. The PoC `Tank.Container` GenServer
  was renamed to `Tank.Runtime`, freeing the struct name.)*
- **M4 — `Tank.Runtime` actuator + macvlan.** One pod spec → running reality:
  pull → spawn → rootfs setup → macvlan network (**static IPs**) → cgroup limits
  → proceed. A pod's netns may hold several `%Tank.Nic{}`. *(done — `Tank.Runtime`
  drives the full host-side bring-up: `Tank.OCI` run params, `Runtime.Rootfs`
  (+ `Etc` for per-pod `/etc`), `Runtime.Network` (macvlan create-in-host →
  move-to-netns), `Runtime.Limits` (cgroup v2); supervised, restart per policy,
  cgroup/scratch torn down on exit. Scope: one container per pod (M7 for more),
  root-in-container/no userns, stdio → `/dev/null`. Cgroup limits are imperative
  — there is no `Cgroup.Reconcile`. Verified end-to-end on real alpine.)*
- **M5 — `Tank.Reconciler`.** The control loop over the Khepri projection;
  start/stop/restart; exponential backoff; self-healing; level-triggered resync.
- **M6 — `Tank.Host` seam.** The `Tank.Host` behaviour + `Tank.Host.Static`
  default (uplink + DNS from config); `parent: :auto`. VintageNet/Linx adapters
  are consumer-side / later.
- **M7 — Multi-container pods.** Sidecars sharing the pod's netns and lifetime.

**Later (post-graduation):** bridge+NAT networking (`Linx.Netfilter`),
DHCP-client-in-netns, `userns` root-remap + idmapped rootfs, overlayfs layer
stacking, multi-node clustering + a pod scheduler, and lifting Tank to its own
repository.

## Non-goals

- Full OCI **Runtime Spec** `config.json` / `runc` CLI compatibility — Tank runs
  images, it is not a compliant runtime.
- **Pluggable CNI** — Tank is opinionated; networking is macvlan (then bridge),
  not a plugin surface.
- **YAML** — desired state is Elixir data in Khepri.
- A **cluster scheduler** — single-node now; the consistent state tree is in
  place for when scheduling is added.

## Risks / open questions

- **The Linx mount gap (M2)** — *resolved.* The rootfs spike needed in-namespace
  proc/dev setup (pidns-aware proc mount, bind `create:`) plus `Linx.Process`
  `:cwd`; all landed in Linx. The standing discipline: make the container's mount
  ns rec-private before any in-container mount, or mounts propagate back to the
  host.
- **Ra on flash** — the Raft WAL + snapshots wear flash; mitigated by Tank's low
  config write-volume and a deliberately chosen data dir (TankOS's job).
- **macvlan on Wi-Fi** — APs commonly refuse it; bridge/`:host` is the fallback.
- **`Tank.Container` rename** — *done (M3).* The PoC `Tank.Container` GenServer
  is now `Tank.Runtime`; `Tank.Container` is the desired-state struct. M4 grows
  `Tank.Runtime` from a single-container PoC into the pod actuator.
- **Container log capture (M4-adjacent gap)** — `Linx.Process` applies its
  `:stdio` directive *in the child, after `proceed`* — i.e. after `pivot_root`.
  A host path (the `connect_unix` socket) is therefore unreachable from the
  pivoted rootfs, so the current stdio mechanism can't carry a container's
  stdout/stderr to a host-side log sink. Capturing container logs needs the
  output fd wired up *before* the pivot (a pre-connected fd inherited across
  exec, or a Linx.Process option for it). Out of M4 scope (M4 sends container
  stdio to `/dev/null`); revisit when logging is built.
