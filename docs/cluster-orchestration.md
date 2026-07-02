# Tank — Clustered Orchestration Build Scope

What needs to be built **inside Tank (and TankOS)** to run stateful,
highly-available workloads on a small cluster, on top of what single-node Tank
already is.

The companion document [`user-experience.md`](user-experience.md) describes the
*outside* — the handful of things a non-technical owner ever sees. This document
is the *inside*: the machinery that makes that simple surface true. **The
internals are complex on purpose, so that the surface can be short.**

---

## 0. Framing

**Tank already is:** a declarative, single-node container orchestrator built on
Linx, persisting desired state to Khepri, with OCI command/env merge and a
reconcile-to-desired-state model.

**The Tank / TankOS boundary is not host-vs-container — it is bootstrap (day-0)
vs orchestrated (day-1):**

- **Tank** = the engine. Everything that is desired-state in Khepri and actuated
  via Linx: containers, the full network + firewall stack, the two HA primitives,
  the reconcile loop. **Khepri is private to Tank** — nothing else reads or
  writes it; the dependency direction is TankOS → Tank → Khepri.
- **TankOS** = the appliance. Only what must exist *before* Khepri does (Nerves
  firmware + day-0 bootstrap: bring links up, peer discovery, WAN uplink), plus
  the web UI, the TappShop, the blessed Tapps, and backups. The web UI is a
  TankOS component, **not** a Tapp — it must run before any Tapp exists.

This document is the **delta** that turns single-node Tank into a clustered
engine. Tank stays generic; anything database-, transport-, or appliance-specific
lives outside it (see §14).

The core primitive Tank offers is **leased single-writer role assignment**: a
generic guarantee that *at most one member of a group holds the "master" role at
any instant, and every member always knows its current role* — plus a trivial
**symmetric-replicated** pattern for leaderless workloads.

---

## 1. Vocabulary — Service, Tapp, meta-Tapp

Do not let one word mean two things.

- **Service** — the atomic unit: one OCI container + its run spec (scale, pattern,
  endpoint, and the role hooks/watermark if stateful). It `provides:` a capability
  and `requires:` the capabilities its own code calls (intrinsic, travels with the
  image).
- **Tapp** — a package: the curated, versioned, **signed** bundle in the shop. One
  or more services + default scale/wiring/typed parameters. The unit of install,
  trust, and refcount.
- **meta-Tapp** — a Tapp that depends on other Tapps and ships no workload of its
  own: a Debian **metapackage**. Allowed, but **stay Debian, not Helm**: resolution
  flattens to one set with one version per service; configuration is **typed
  parameters** each service declares, never free-form templating; one refcount
  graph; **zero imperative orchestration logic** in a package.

**Composition is declarative, in the Tapp metadata.** Containers *can* share a
namespace — a Service is **one main container plus an optional Tank-agent sidecar**
(§7) — but that composition is declared by the **Tapp author** in the package
metadata, never assembled by the operator and never an ad-hoc runtime step. The
scheduler runs `scale`-many instances and binds them to nodes. The unit is bounded
by **role**: things that scale or fail over independently are **separate Tapps**
(the PBX is a controller Tapp + an rtpengine Tapp, not one multi-container unit).

---

## 2. The keystone — persistence is concentrated, not general

The single decision that lets Tank *not* be Kubernetes: **Tank offers no general
or replicated volumes to apps. Persistence is concentrated in a few stateful
provider services; every other service is stateless and ephemeral and persists
*through* them.**

Local persistent storage still exists — it is a capability a service can
**request** (a named, node-local volume, §13) — but it is used by the provider
services, and requesting it **pins** that service to its node. There is no
distributed/replicated volume layer and no PVC/CSI machinery; replication is each
provider's own job. This is what removes the StatefulSet problem at the root while
still letting Postgres and Garage keep their data.

The first two providers are **blessed Tapps**: `postgresql` provides the `:sql`
capability, `garage` provides `:s3`. They are not special platform features — the
capability/provider model **generalizes**, so a future database, queue, or KV
store is just another provider Tapp (§8). The web UI presents capabilities as
"Databases" / "Object storage"; Tank only ever sees "a leased-writer service" or
"a symmetric service" with a local volume.

---

## 3. The workload patterns

| Pattern | For | Tank's job | Example |
|---|---|---|---|
| **Stateless** | most Tapps | schedule per preference; ephemeral rootfs; expose endpoint | PBX, Hive, LLM apps |
| **Symmetric-replicated** | leaderless stores | schedule N, pin local disk each, expose endpoint, **no role logic** | Garage |
| **Leased single-writer** | single-writer stores | lease + role assignment + fencing + safe promotion | Postgres |

The workload's data model picks the pattern. Tank does not try to unify
single-writer and leaderless behind one abstraction.

---

## 4. Lease primitive over Khepri — *the authority*

The one piece whose correctness comes from consensus. Acquire/renew/release the
master role as an **atomic compare-and-set committed through Ra/Raft**.

- Single-*holder* is a consequence of majority-commit: a rival loses the race
  (only one commit is first on the key); a partitioned-away node **cannot win at
  all** (can't reach a majority). Single-*writer* additionally requires fencing
  (§5) — the lease alone grants the token, not write exclusivity.
- The lease carries `{holder, expiry, epoch}` with a TTL. `epoch` increments **on
  grant, not on renewal**, and is the fencing token a new master carries so the
  in-container agent can reject a stale promote.

```elixir
# Atomic, through Raft. Returns :acquired / :renewed ONLY if it committed to a
# majority. On a minority partition this CANNOT commit -> it returns an error.
# NOTE: the transaction fn runs on every Ra member and MUST be deterministic —
# `now` is passed IN (captured before the call), never read inside.
def try_acquire(node, now) do
  Khepri.transaction(fn ->
    case Khepri.get(@lease_path) do
      :error                              -> put(node, now); :acquired   # free
      {:ok, %{holder: ^node}}             -> put(node, now); :renewed    # mine
      {:ok, %{expiry: e}} when e < now    -> put(node, now); :acquired   # expired
      {:ok, _valid}                       -> :denied                     # held
    end
  end)
end
```

Keep `:lease` (churny — renews every ~TTL/3) and `:master` (slow — changes only
on failover; transports subscribe to it) as **separate Khepri keys**, so the
renewal stream doesn't wake every endpoint consumer.

**Build:** lease module (acquire/renew/release/read), TTL + epoch handling,
expiry evaluation that does not require reaching the holder.

---

## 5. Fencing model — *the invariant*

- **Self-fence** (lease-loss, local **monotonic** clock, stop by `TTL − δ`) —
  always available, needs no communication; covers the partitioned/isolated node.
  Must use monotonic time, immune to NTP steps.
- **Active fence** (Tank kills the container) — fast path, only when reachable.
- **Ordering invariant (non-negotiable):** the old master is provably **mute
  before** any new master is **writable**. Guaranteed by `self-fence at TTL − δ`
  + `lease not grantable until expiry`.
- **`δ` must cover** clock skew + stop latency + renewal-commit propagation — not
  just "skew + stop." Write it as an explicit inequality; `δ` is the entire safety
  margin. Validate at install that a service's declared TTL is larger than the
  shared failure-detector window (§10), and reject otherwise.

**Build:** the `δ` accounting, enforcement of mute-before-writable across both
fence paths.

---

## 6. Cluster controller + node reconciler — *the brain and the hands*

Two **distinct** reconcile loops; do not conflate them.

**Cluster controller** — runs on the Ra leader. *Decides*, and writes Khepri:
- Placement / bindings (§9), master selection + grant, IPAM allocation,
  provisioning (§11). Because admin state lives in Khepri, any node can become the
  controller when it becomes leader — no single point of failure.
- **Master selection (correctness, not preference):** promote the **highest
  watermark** healthy member — it provably holds every acknowledged write.
  Equal watermarks → free choice (data identical). **No safe candidate → refuse to
  promote, stay down** (consistency over availability).
- Selection is only ever run over a **quiesced group** (a free lease ⇒ the old
  master is fenced ⇒ no new writes ⇒ watermarks are frozen). *Open hard problem:*
  "highest watermark" is only globally safe if enough members are heard from — the
  selection quorum is distinct from the Raft quorum, and for a 2-replica
  deployment safety depends on the workload using **synchronous replication**
  (a Tapp concern, §14).

**Node reconciler** — today's `Tank.Reconciler`, one per node. *Realizes* its
slice: the services bound to it, their network resources (§10), self-fencing.
Reads Khepri (durable desired) + local/gossiped health (live).

### NodeAgent (per-node, host-side, part of Tank)
- **Renew** the lease on a timer while this node is master.
- **Self-fence** per §5.
- **Relay** roles and endpoint-change events to the in-container agent over the
  control socket (§7).
- **Inject** credentials at container launch (§11); start/stop/kill via Linx.
- **Report** `{healthy, role, watermark}` over messaging (not Khepri).

> **Two agents, two scopes.** The **NodeAgent** (host-side, generic, one per node)
> does the actions above. The **Tank-agent sidecar** (§7, in the service's
> namespace, one per provider instance) does the *service-specific* contract verbs
> (provision, backup, role transitions). The NodeAgent brokers Tank's calls to the
> sidecar. The sidecar is off the data path — if it dies the service keeps serving,
> only provisioning/backup pauses until it restarts.

**Build:** the controller loop (selection, refuse-when-unsafe, dispatch), the
NodeAgent (renewal/self-fence timers, health reporting, cred injection, Linx
actuation).

---

## 7. The Tank-agent contract — *a sidecar (or built-in), opt-in verbs*

What makes leased-single-writer (and managed services generally) reusable instead
of Postgres-specific. A small **Tank-agent** implements whichever standard verbs the
service opts into — **by default as a sidecar container sharing the service's
namespace**, so the **main image stays stock/upstream** (unmodified `postgres`,
`garage`); or built into the image. It reaches the service **locally** (unix socket
/ localhost) using the same Linx *enter-an-existing-namespace* primitive that
`Tank.exec`/`attach` already use — only pointed at launch time. Tank defines the
contract; the agent implements it; Tank never knows DB/S3 specifics (upholds §14).

```
# provisioning — admin creds NEVER leave the namespace (local socket / peer auth)
Tank  -> agent : provision(consumer_id, resource)   -> {connection creds}   # idempotent
Tank  -> agent : deprovision(consumer_id, resource) -> :ok
#   resource is the provider's kind: :database (postgresql), :bucket (garage), …

# leased-writer role transitions
Tank  -> agent : on_promote
Tank  -> agent : on_follow(endpoint)
Tank  -> agent : on_demote

# health / selection / backup / introspection
agent -> Tank  : status -> %{healthy, role, watermark}   # watermark is opaque, ordered
Tank  -> agent : backup / restore / describe
```

- The agent talks to the service over its **local socket (peer auth)** from inside
  the shared namespace — often with **no admin password at all** — so it hands Tank
  only **scoped consumer creds**, and Tank holds **zero admin secrets**. `provision`
  is **idempotent**, so Tank re-fetches on every launch and **stores nothing** —
  Khepri stays secret-free.
- `describe` lets Tank verify the running agent matches the manifest (drift check).
- The watermark's *meaning* is the workload's; Tank compares it as an opaque
  ordered value.

**Build:** the control-socket transport + injection, the message schema, the Tank
side of each verb, and **launching the sidecar into the main container's namespace**
(Linx already enters existing namespaces — the same primitive behind `Tank.exec`).
The agent itself (sidecar image, or built-in) ships per-workload.

---

## 8. Dependency graph — `requires` / `provides`

One uniform model, and the system's main extensibility point.

- A Service `provides:` a **capability** — the abstract category — while the Tapp
  is the concrete **provider**: `postgresql` provides `:sql`, `garage` provides
  `:s3`.
- A Service `requires:` a capability **plus the resource to provision** from it:
  Hive requires *a `:sql` database*; pbx-controller requires *a `:sql` database, an
  `:s3` bucket, and the `:rtpengine` service*. Tank resolves the capability to a
  provider (the blessed default, or one the engineer pins), then calls that
  provider's agent to create the named resource and inject access (§7, §11).
- **This generalizes:** any future persistent system is just another provider Tapp
  — `redis` provides `:kv` (provisions a keyspace), a broker provides `:amqp`
  (provisions a vhost), another engine provides `:sql`. Tank's code never changes;
  it only speaks the generic `provision`/`deprovision` contract.

Resolution is **apt-style, not Helm/SAT**:
- Auto-install a pinned/recommended dependency if absent; **refcount** providers;
  **autoremove** when the last requirer goes (data-bearing services marked
  `keep`).
- **No version solver** — pin tested combinations. A meta-Tapp flattens to one
  version per service; a version **conflict is refused and surfaced**, never
  silently resolved.
- Shared providers are singletons (one Garage serves all requirers); the engineer
  may deploy/scale a provider explicitly, and consumers bind to whatever exists.
- Readiness is **reconcile-to-ready**, not hard ordering — a requirer starts and
  discovers its dependency as it becomes ready; no install-time deadlocks.

**Build:** the capability graph, refcount/autoremove, conflict detection, the
provisioning binding (§11) per requires-edge.

---

## 9. Scheduling & scaling — *new for multi-node*

- **Binding (spec/binding split, ≈ k8s `nodeName`).** Each instance carries a
  `:spec` (node-independent, operator/package intent) and a `:binding`
  (`{node, epoch, at}`, controller-written). A node realizes the instances bound
  to it.
- **Preference scaling (stateless):** `scale: %{min, preferred, max}`; the
  scheduler runs `clamp(preferred, min, suitable_nodes)`, spread across failure
  domains (node `:labels`). One node → runs degraded (the UI says "add nodes for
  HA"). Witness nodes are **excluded** from placement.
- **Stateful counts are exact** (Postgres replicas, Garage replication factor) —
  tied to quorum/replication, not cluster size.
- **Failure responses differ by kind.** A stateless instance on a dead node is
  **rescheduled** elsewhere. A stateful instance is **not** moved (its data is on
  the dead node) — failover is *replica promotion* (§4); the orphaned instance
  waits for its node/volume to return.
- **Volume pin** (§13) constrains placement: an instance with node-local data is
  schedulable only where that data lives.

**Build:** the placement engine, constraint handling, preference clamping,
failure-triggered rescheduling (leader-driven, recorded in Khepri).

---

## 10. Networking & endpoints

**Full IPv6 internally.**

- **Day-0 discovery** over IPv6 **link-local** (zero-config): bring links up,
  discover peers (`mdns_lite` or `libcluster` Gossip), form the Erlang cluster +
  Khepri quorum. This keeps the bootstrap layer tiny.
- **Day-1** is reconciled from Khepri. Plan: retire vintage_net and do link
  configuration via **Linx** (phased — vintage_net and Linx coexist meanwhile,
  vintage_net owning physical links, Linx owning container netns). The WAN uplink
  (WiFi/DHCPv4/PPPoE) stays heavier and is day-0/TankOS.
- **Positive ownership** of network resources: the reconciler **never deletes what
  it can't prove it created**. Scope "actual" by marks — a dedicated route `proto`
  number, address pools, a link-name prefix (`tk-*`). Physical NICs are never
  created by Tank → never reaped. IPv6 makes it **additive** (layer addresses,
  never replace). The only fact day-0 hands Tank is the uplink
  (`Tank.Host.uplink/0`).

**Endpoint shapes** (names generated from each service's declared `endpoint.mode`,
resolved via DNS):

- **Floating /128** — leased-writer master, and **all external-facing** endpoints
  (e.g. phones → PBX). Tank maintains the address as a fact; Linx moves it; it
  follows `:master`.
- **Node-local same-IP** — symmetric services. The *same* /128 on every node, each
  node routing it to its **local** instance (never advertised between nodes, so no
  conflict, **no BGP**). Free locality; the headless list is the fallback if the
  local instance is down.
- **Headless** — every replica, individually addressable (app-internal clustering,
  fan-out). Built from the IPAM address map already in Khepri.
- *True ECMP anycast is a later optimization that arrives with BGP* (a routing
  daemon run as a Tank-managed Tapp, fed by Tank's facts).

**Current-master publication + change events.** Tank keeps the authoritative
`master = node X` in Khepri and emits change events when it moves. The *transport*
that acts on it (floating /128, NDP, DNS) consumes these events.

**Instance-down / endpoint-change events** (the shared nervous system):
- "Down" has three sources: container exited (local, immediate, high-confidence),
  unhealthy (local check), **whole node gone** (detected by absence among infra
  members — the hard case, detector-bound).
- **Deliver state, not deltas** — the full current endpoint set on every change
  (level-triggered, self-healing). Computed = durable bindings ∩ live-healthy
  (health flows over messaging, never Khepri).
- Carry a **reason** (`container_exited` vs `node_unreachable`) so each consumer
  tunes its own sensitivity. Infra components subscribe via Khepri watches; **Tapps
  subscribe via their local NodeAgent over the control socket** (never joining the
  infra cluster, never touching Khepri).
- **The detector is an availability knob, not a safety knob.** A false positive
  only makes the controller *attempt* a promotion; the lease CAS rejects it (a live
  master is still renewing) or self-fencing guarantees safety (a partitioned master
  can't renew). So the PBX can run an aggressive detector without endangering
  Postgres. One node-failure detector is **shared** cluster-wide; lease TTL, health
  checks, and consumer debounce are per-service.

**Images.** Tapp images download from the TappShop; **Garage/S3 is an opportunistic
cache** (warm at install for offline failover), **not** a dependency — no Garage
just means images download normally, so there is no bootstrap circularity.

**Build:** day-0 discovery, Linx link/address/route config, ownership marks, the
endpoint-mode resolver + DNS publication, the master/endpoint change-event bus, the
shared failure detector.

---

## 11. Credentials & secrets

`requires: [:sql, :s3]` becomes real via the §7 provisioning contract:

- Tank calls the provider's `provision(consumer_id)` to get **per-consumer scoped**
  creds (own db/role, own bucket/key); the provider's admin credential never leaves
  its container. Tank injects the returned creds into the consumer via **env vars +
  a tmpfs `/run/secrets` mount** — reusing existing `Tank.OCI` env-merge and
  `Tank.Runtime`/`Etc` mount machinery. Reschedule-safe (re-minted/re-fetched at the
  destination; nothing secret travels between nodes).
- **Auth is bootstrapped by Tank at launch** (Tank starts the container, so it
  injects the trust), symmetric in two directions:
  - **Tank → provider:** an ENV token injected into the provider container, presented
    when calling the provision API.
  - **container → NodeAgent:** a per-container ENV token the container presents to its
    NodeAgent to prove "I am *this* container, nothing else" (the mailman rule).
  - Both tokens minted fresh per launch, re-injected on reschedule.

**Security model — deliberately simple; at-rest encryption is DEFERRED.** Physical
theft = full data exposure, explicitly accepted (the Postgres/Garage data is
plaintext on disk anyway, so encrypting only creds would be theater). Therefore: **no
cluster key, no TPM sealing, no recovery code.** When at-rest security is wanted
later, the right answer is **full-disk encryption (LUKS + TPM/passphrase)**, which
covers data *and* creds uniformly — not app-level per-secret encryption.

The boundary that **does** hold (and defends the realistic *remote* breach, not
physical theft): **a Tapp cannot reach Khepri or the control plane.** A popped
container gets only its own scoped creds via its NodeAgent — its blast radius is its
own database and bucket. This is the same isolation boundary the cluster uses
operationally, now also serving as the security boundary.

**Build:** the provisioner (calls provider agents, follows leadership), the two ENV
token flows, env + tmpfs injection wired into `Tank.Runtime`.

---

## 12. Khepri / Ra clustering

Tank currently uses Khepri single-node; clustered Tank enables Ra clustering.

- Multi-node Ra membership; node **join / leave**. A **join token** (cluster
  integrity, not at-rest secrecy) + the cluster's cert fingerprint secures the
  link-local handshake; the operator approves a new node in the UI.
- Growing 1 → 3 nodes is a **live Ra membership change** — quorum math shifts
  (1 → 2); the join flow drives the reconfiguration.
- Quorum awareness: real HA needs **3 voting members**; support a **witness**
  (voting, workload-free) so a 2-real-node home cluster can form a majority.
- Surface "waiting for quorum" honestly rather than hanging on partial restart.
- Khepri stays **secret-free** (binding identities and grants, not passwords) and
  holds durable authority only (lease, master, bindings, IPAM, config); live
  health/watermarks stay in messaging.

**Build:** cluster bootstrap/join/leave + join token, Ra membership reconfiguration,
witness support, quorum-state reporting.

---

## 13. Local storage & volumes

Local persistent storage **is** a capability Tank provides — a service may request
a **named, node-local volume** (identity + lifetime independent of any container,
local-by-default). But it is used by the **stateful provider services** (the ones
backing capabilities like `:sql` / `:s3`), not offered as a general per-app
feature, and requesting it **pins that service to its node** (§9).

- App services stay **ephemeral** and persist *through* the providers (§2); they
  do not request volumes.
- Tank provides **no replicated/distributed volumes** and no PVC/CSI machinery —
  replication is each provider's own job (Postgres replicates; Garage replicates).
- Garage additionally serves as the opportunistic **image cache** (§10).

**Build:** the named-volume identity/lifecycle, mount wiring (via Linx /
runtime-spec), placement-constraint emission to the scheduler.

**Build:** the data-dir identity/lifecycle, mount wiring (via Linx / runtime-spec),
placement-constraint emission to the scheduler.

---

## Key invariants (the things that must always hold)

1. **Authority through Raft, orchestration in GenServers.** The grant of the master
   role is a Raft-committed CAS; everything else (selection, polling, hooks, timers)
   is ordinary BEAM work.
2. **Single-writer via majority-commit + fencing** — never via distributed-Erlang
   singletons / `:global` / heartbeats (partition-unsafe).
3. **Mute before writable** — old master fenced before new master promoted.
4. **Promote highest watermark; refuse if none safe; arbitrary only on exact
   equality** — and only over a quiesced group.
5. **Self-fence on the local monotonic clock**, independent of any received message.
6. **Khepri holds no secrets and no live telemetry** — durable authority only.
7. **Tapps never reach Khepri or the control plane** — the isolation = security
   boundary; the NodeAgent only ever hands a container its own scoped creds.
8. **No word means two things** — Service (container) ≠ Tapp (package). Container
   composition is **declarative, in the Tapp metadata** (a Service is one main
   container + an optional Tank-agent sidecar, §7); the operator never composes,
   and independently-scaling things are separate Tapps.

---

## 14. Explicitly NOT in Tank (lives elsewhere)

- **Postgres mechanics** (`pg_promote`, `pg_rewind`, `standby.signal`, **synchronous
  replication** config), and the `provision/deprovision` SQL → in the **Postgres agent
  sidecar** (a stock `postgres` image + a Tank-owned `pg-agent`). Likewise Garage's
  admin API → the **Garage agent sidecar**.
- **Network actuator / fabric** (BGP/BFD for true anycast, NDP, floating-IP transport,
  DNS serving) → **TankOS** (Tank publishes the facts and events it consumes).
- **At-rest encryption / full-disk encryption** → deferred; a TankOS/Nerves concern
  when revisited.
- **Garage, Stevedore wiring, blessed images, the TappShop, the web UI, backups,
  "add a node" UX, Nerves firmware** → **TankOS / Tapps**.
- **Replication correctness / data durability** → the **workload's** job. Tank
  guarantees *one master, safely*; only the workload's own sync/quorum settings can
  guarantee no acknowledged-data loss.
