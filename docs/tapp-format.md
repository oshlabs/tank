# The Tapp Format

> **Status: exploratory sketch — not final.** This is the working design for the
> Tapp package format. Field names and shapes will change. The eventual home for
> this document is the **`tapp` library** (see §0); it lives in the Tank repo for
> now while the design settles.

A **Tapp** is the unit a user installs from the TappShop. This document defines
what a Tapp *is* as data: its structure, every field a Service can declare, the
`provides`/`requires` model, and the runtime agent contract. The companion docs are
[`cluster-orchestration.md`](cluster-orchestration.md) (how Tank *runs* this) and
[`user-experience.md`](user-experience.md) (what the user *sees*).

---

## 0. What this is and where it lives

The format is defined by a standalone **`tapp` library**, shared by everything that
needs to understand a manifest:

```
            tapp (lib)  — structs + validation + (de)serialization + version
                        + dependency types + a PURE resolver
            ╱        ╲
        Tank          TappShop
   (interprets)    (catalogs / signs / serves / displays)
        │
   TankOS UI
```

- **In the lib (pure, no side effects):** the structs, `new/1`-style validation, a
  canonical serialization for storage/signing, the schema version, and a pure
  dependency resolver (available Tapps + a request → the install set).
- **Not in the lib:** scheduling/running/provisioning (Tank); hosting/signing/serving
  (TappShop).
- **Lowering boundary:** the lib defines the *portable package format*; Tank lowers a
  *bound Service instance* into its internal runtime spec when it schedules. The
  package format is the stable public API; the runtime model is Tank's private detail.

This mirrors how Tank already composes `stevedore` and `linx` — focused libs, Tank
on top.

---

## 1. The three artifacts

| Artifact | Is | Has |
|---|---|---|
| **Service** | one OCI container (+ optional Tank-agent sidecar, §3 G) + run spec | the bulk of the schema (§3) |
| **Tapp** | a signed package | identity + `services: [Service, …]` + package `params`/`requires` |
| **meta-Tapp** | a package of packages (Debian metapackage) | identity + `requires: ["pbx", …]` + `params`, **no services** |

A single-service Tapp is the common case. **Container composition is declarative, in
this metadata** — a Service is one main container plus an optional Tank-agent sidecar
(§3 G), composed by the Tapp author here, never by the operator and never ad-hoc at
runtime. The scheduler runs `scale`-many instances and binds them to nodes.
Independently-scaling things are separate Tapps, not one multi-container unit.

---

## 2. Package level — the Tapp

```elixir
%Tapp{
  # identity & trust
  name:        "pbx",
  version:     "2.1.0",
  vendor:      "exquisip",
  # signature is attached by the TappShop, not hand-authored

  # shop & dashboard
  ui:          %{display: "PBX", description: "...", category: :telephony, icon: "..."},

  # what it runs
  services:    [ %Service{...}, ... ],

  # package-level external needs (pulls in providers) and user-facing config
  requires:    [ %{use: :sql}, %{use: :s3} ],
  params:      [ ... ]                 # surfaced to the user / a parent meta-Tapp
}
```

A **meta-Tapp** drops `services` and lists `requires: ["pbx", "hive"]`. Resolution
flattens the whole tree to one set with one version per service; a version conflict
is **refused and surfaced**, never silently resolved. Config is only via the typed
`params` each member exposes — **no templating, no imperative logic** in a package.

---

## 3. Service schema

Grouped. Each field notes **owner** — `[author]` Tapp author, `[user]` set at
install, `[eng]` advanced/engineer, `[Tank]` derived/managed — and **when** —
`v1` core, or `later`.

### A. Image & process
| field | purpose | owner | when |
|---|---|---|---|
| `image` | OCI image ref (pulled via Stevedore) | author | v1 |
| `command` `args` `env` | overrides, merged over the image config (`Tank.OCI`) | author, eng | v1 |
| `working_dir` `user` | process working dir / uid | author | v1 |

### B. Placement & scale
| field | purpose | owner | when |
|---|---|---|---|
| `pattern` | `:stateless` \| `:leased_writer` \| `:symmetric` | author | v1 |
| `scale` | `%{min, preferred, max}` (stateless — clamps to nodes) | author / eng | v1 |
| `replicas` | exact N (stateful — quorum/replication) | author | v1 |
| `spread` | failure-domain anti-affinity (node `:labels`) | author | v1 |
| `node_select` | constraints: arch, has-GPU, custom labels | author | later |
| `resources` | requests for placement (mem/cpu) — scheduler bin-packs | author | later |
| `limits` | cgroup caps (mem/pids/cpu) — exists today | author / eng | v1 |

### C. Storage
| field | purpose | owner | when |
|---|---|---|---|
| `volumes` | `[%{name, size, kind: :local}]` — node-local persistent; **pins** the service | author | v1 |

Used by stateful provider services (§2 keystone of cluster doc). App services stay
ephemeral and declare no volumes.

### D. Networking
| field | purpose | owner | when |
|---|---|---|---|
| `addresses` | `[%{name, kind, scope, port}]` — the IPs it needs | author | v1 |
| `ingress` | external exposure: protocol + port (TLS / hostname) | author / user | v1 basic, TLS+host later |
| `network_policy` | who may reach it (default: open intra-cluster) | eng | later |

`kind` ∈ `:floating` (one on the active/master node) · `:node_local` (same IP every
node → local instance) · `:headless` (one per instance) · `:static` (fixed, e.g.
carrier ACLs). A service may need several (PBX: floating external + headless internal).

### E. Provides — what it offers (granular)
```elixir
provides: [
  %{service:   :sql, on: "sql"},            # consumers connect to this capability
  %{provision: :instance, as: :database},   # Tank can mint a named database
  %{provision: :access,   as: :role},       # Tank can mint scoped user/pass
  %{stats:     :prometheus}                 # Tank/UI can scrape metrics
]
```
`:instance` and `:access` are separate because they have different cardinality (a
database per *app*; credentials per *instance*). All `[author]`, v1 (stats: later).

### F. Requires — what it needs (simple)
```elixir
requires: [
  %{use:   :sql},                      # "a usable SQL database" — Tank orchestrates instance+access
  %{reach: :rtpengine, version: ">= 11", optional: false}
]
```
`use:` = provision a resource + inject creds; `reach:` = discover + connect, nothing
minted. The consumer never names the provider's internal grain — Tank sequences it.
All `[author]`, v1.

### G. Agent — the Tank contract (sidecar by default)
A small **Tank-agent** implements the runtime verbs. By default it runs as a
**sidecar** sharing the service's namespace, so the **main image stays stock/upstream**
(unmodified `postgres`, `garage`); or it is built into the image. Tank launches the
sidecar into the main container's namespace via Linx's existing
*enter-an-existing-namespace* primitive (the same one behind `Tank.exec`).

```elixir
agent: %{
  mode:  :sidecar,                 # default — stock main image + this sidecar
  image: "tank/pg-agent:16",
  verbs: [:provision, :deprovision, :role_hooks, :status, :describe, :backup, :restore]
}
# or  mode: :builtin  — verbs implemented inside the main image (no sidecar)
```

| verb | purpose | when |
|---|---|---|
| `provision(consumer, resource)` / `deprovision` | mint/remove a scoped resource (idempotent) | v1 |
| `status` | `{healthy, role, watermark}` | v1 |
| `describe` | report the contract → Tank verifies it matches the manifest | v1 |
| `on_promote` / `on_demote` / `on_follow(endpoint)` | leased-writer role transitions | v1 (leased-writer) |
| `stats` | metrics for the dashboard | later |
| `backup` / `restore` | the provider knows how (`pg_dump`, garage snapshot) | v1 for blessed providers |

Transport: the control socket; the sidecar reaches the service over its **local
socket** (peer auth), so admin credentials never leave the namespace — often there
is no admin password at all.

### H. HA & lifecycle
| field | purpose | owner | when |
|---|---|---|---|
| `lease` | `%{ttl}` (leased-writer) — conservative; validated > detector window | author | v1 |
| `watermark` | how it's read (leased-writer) — opaque ordered value | author / agent | v1 |
| `liveness` | `%{sensitivity}` — how aggressively endpoints are declared down | author | v1 |
| `restart` | `:always` \| `:on_failure` \| `:never` — exists today | author | v1 |
| `update` | `%{strategy: :rolling \| :recreate, leader_last?}` — zero-downtime upgrades | author | v1 basic, leader-last later |
| `shutdown` | `%{drain, signal}` — graceful stop / connection drain | author | later |
| `backup` | schedule + destination (USB / external S3); agent performs it | user / agent | v1 for providers |

### I. Clustering (app-internal)
| field | purpose | owner | when |
|---|---|---|---|
| `cluster` | `:erlang` \| `:gossip` \| `:none` → injects cookie + headless sibling DNS | author | v1 |

A Tapp's internal cluster is **separate** from TankOS's own (different cookie; never
joins the infra cluster).

### J. Health
| field | purpose | owner | when |
|---|---|---|---|
| `health` | `%{ready, live}` — exec/tcp/http probe, or via the `:status` agent verb | author | v1 |

Gates endpoint membership, rolling updates, and down-detection.

### K. Config & secrets
| field | purpose | owner | when |
|---|---|---|---|
| `params` | typed knobs (debconf-style): default + range/type | author defines / user, eng set | v1 |
| `inputs` | user-supplied **secrets** (e.g. an LLM API key): `%{type: :secret, required}` | user | v1 |

`inputs` (user provides) are distinct from **provisioned** creds (Tank mints — §11 of
the cluster doc) and from injected platform tokens (the two auth tokens).

### L. Observability
| field | purpose | owner | when |
|---|---|---|---|
| `stats` | metrics endpoint (or `:stats` agent verb) | author | later |
| `logs` | stdout/stderr collection (where / retention) | Tank | v1 default |

---

## 4. Examples

**Trivial stateless web app** — most Tapps look like this:
```elixir
%Tapp{name: "notes", version: "1.0",
  ui: %{display: "Notes", category: :productivity},
  services: [
    %Service{
      image: "tankshop/notes:1.0",
      pattern: :stateless,
      scale: %{min: 1, preferred: 3},
      addresses: [%{name: "web", kind: :floating, scope: :external, port: 8080}],
      ingress: %{protocol: :http, port: 8080},
      requires: [%{use: :sql}],
      health: %{ready: {:http, "/health"}}
    }
  ]}
```

**Provider — postgresql provides `:sql`** — lights up most of the schema:
```elixir
%Tapp{name: "postgresql", version: "16.2",
  ui: %{display: "PostgreSQL", category: :data},
  services: [
    %Service{
      image:   "tankshop/postgresql:16.2",
      pattern: :leased_writer,
      replicas: 3,
      addresses: [%{name: "sql", kind: :floating, port: 5432}],
      volume:  %{name: "pgdata", size: "20G"},
      provides: [
        %{service: :sql, on: "sql"},
        %{provision: :instance, as: :database},
        %{provision: :access,   as: :role},
        %{stats: :prometheus}
      ],
      agent:   %{mode: :sidecar, image: "tank/pg-agent:16",
                 verbs: [:provision, :deprovision, :role_hooks, :status, :describe, :backup, :restore]},
      lease:   %{ttl: {8, :s}},
      update:  %{strategy: :rolling, leader_last?: true},
      params:  [max_connections: %{type: :integer, default: 100}]
    }
  ]}
```

**Consumer — the PBX** (rtpengine is its own Tapp, pulled in by `reach`):
```elixir
%Tapp{name: "pbx", version: "2.1.0",
  services: [
    %Service{
      image: "tankshop/pbx-controller:2.1.0",
      pattern: :stateless,
      scale: %{min: 1, preferred: 2},
      cluster: :erlang,
      addresses: [%{name: "sip", kind: :floating, scope: :external, port: 5060}],
      requires: [%{use: :sql}, %{use: :s3}, %{reach: :rtpengine, version: ">= 11"}]
    }
  ]}
```

**Meta-Tapp:**
```elixir
%Tapp{name: "office-suite", version: "1.0",
  requires: ["pbx", "hive"], params: [...]}      # no services
```

---

## 5. Dependency resolution (pure, in the lib)

- A `use:`/`reach:`/package `requires` names a **capability** (`:sql`) — Tank resolves
  it to a **provider** (the blessed default, or one the engineer pins). *(Open: whether
  consumers may also name a provider directly — see §7.)*
- Resolution is **apt-style, not SAT**: auto-install a pinned/recommended provider if
  absent, **refcount** providers, **autoremove** when the last requirer goes
  (data-bearing providers marked `keep`). Pin tested combinations; flatten to one
  version per service; **conflict → refuse + surface**.
- The resolver is a **pure function** in the lib, so both Tank (install) and the
  TappShop UI ("installing this also installs X") use the same logic.

---

## 6. Discipline — thorough ≠ mandatory

The schema is large, but **almost every field is optional with a sane default**. An
author fills in only what their service needs (the trivial app above is ~8 lines; a
provider lights up the lot). The manifest gets **progressive disclosure**, same as the
UI: write what applies, the rest defaults. And it stays **pure declarative data**
(validated by `new/1`) — there is nowhere to inject logic or templates.

---

## 7. Open questions

- **Capability vs provider in `requires`.** Currently a consumer names a *capability*
  (`:sql`), with provider-pinning as an option. Final call deferred.
- **Internal runtime struct naming.** `Tank.Pod`/`Tank.Container` predate the
  declarative-composition framing; the lowering target may eventually want a different
  name. (A `Tank.Workload`
  rename was tried and **reverted** — `Workload` already names the running process via
  `Linx.Process` in `runtime.ex`, and the struct is genuinely a *bounded* multi-container
  namespace, so the name is deferred.)
- **Canonical serialized form.** Elixir terms are the authoring form; a stable
  serialization is needed for storage + signing in the TappShop (and for `describe`
  comparison). Format TBD.
- **`v1` vs `later` split** above is a first cut at build order, not a commitment.
