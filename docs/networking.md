# Networking

How pods get networks, addresses, and names — the design for Tank's pod
networking and the host network services embedded from
[Starfish](https://github.com/oshlabs/starfish) (IPAM now; DNS with this
design; DHCP/RA when TankOS takes router duty). Companion docs:
`cluster-orchestration.md` (the HA future), the plan tree's
`components/tank.md` (store decisions this builds on).

Status markers: **[built]** exists on `starfish-integration`, **[this design]**
is what lands next, **[modelled]** has types/config shape but no actuation,
**[future]** is named so config doesn't paint us into a corner.

## Principles

1. **Mechanism in Tank, policy in config.** Tank knows how to make a macvlan,
   allocate an address, run a DNS listener; *which* networks exist, what the
   domain is, and what binds where is configuration — TankOS, a Debian box,
   and tests each bring their own.
2. **Auto-with-override, all the way down.** Every knob has a derivable
   default; declaring it overrides. A pod with one `{:ipam, subnet}` NIC and
   nothing else gets an address, prefix length, gateway, DNS server, and DNS
   name — all derived from the pool.
3. **Desired state lives in the store.** Pools and listeners are store-backed
   (Starfish's `[:starfish]` subtree of Tank's Khepri store) and runtime
   reconfigurable — the substrate for tank_web's Advanced-mode network view.
   Boot config is declarative: what `config :tank, :net` declares is
   (re)applied on boot; what it omits is left as the store has it.
4. **Allocations are observed state**, reconciled level-triggered (the
   reconciler releases what desired state no longer references) **[built]**.

## The config surface

Everything under one key. All fields optional except a pool's `subnet`.

```elixir
config :tank, :net,
  # IPAM pools (Starfish prefixes) + static bindings. [built — as :ipam]
  pools: [
    %{subnet: "10.0.0.0/24",
      gateway: "10.0.0.1",         # default gateway for pods on this pool
      dns: ["10.0.0.53"],          # default resolv.conf for pods on this pool
                                   #   (defaults to the shim address, see below)
      domain: "tank.internal"}     # per-pool zone origin [this design]
  ],
  reservations: [%{client: "printer", ip: "10.0.0.10"}],

  # The host-side service interface on the pod network. [this design]
  # macvlan pods cannot reach the host over the shared parent (kernel-level
  # isolation), so the host joins each served pool through a shim interface —
  # which is also what gives the host (health checks, tank_web's reverse
  # proxy) a route to its pods at all.
  shim: [
    name: "tank0",                 # default "tank0"
    parent: :auto,                 # default: Tank.Host.uplink()
    pool: "10.0.0.0/24",           # default: the first pool
    ip: :auto                      # default: static IPAM allocation,
  ],                               #   client {:tank_host, :shim}, hostname "tank"
                                   # shim: false disables it (and host DNS duty)

  # The embedded DNS service. [this design]
  dns: [
    origin: "tank.internal",       # default "tank.internal" (never ".local" —
                                   #   that's mDNS's; ".internal" is ICANN-reserved
                                   #   for private use)
    listen: :shim,                 # default: the shim address; or explicit IPs
    port: 53,
    upstream: ["9.9.9.9"],         # default: Tank.Host.dns() (the site's own)
    zones: []                      # extra static zones, passed through
  ],                               # dns: false disables the listener

  # Defaults applied to pod NICs that don't say otherwise. [modelled]
  nic: [mode: :macvlan, parent: :auto]
```

### Networking modes

Per-NIC `mode`, defaultable via `nic:` above:

- `:macvlan` **[built]** — pod joins the parent's L2 network as a first-class
  citizen. The v1 mode; implies the shim for host↔pod traffic.
- `:host` / `:none` **[built]** — pod-level shortcuts (share the host netns /
  loopback only).
- `:ipvlan` **[modelled]** — same shape as macvlan for MAC-restricted
  networks (one MAC per port); shares macvlan's host-isolation caveat (L2
  mode) so the shim story carries over.
- `:bridge` **[modelled]** — a Tank-owned bridge + veth pairs: pods on a
  private L2 behind the host instead of on the LAN. No shim needed (the
  bridge itself is the host's interface); pairs naturally with `:routed`.
- `:routed` + firewalling **[future]** — the host routes (and NATs/filters)
  between a private pod network and the uplink: nftables rules as desired
  state, per-pool `masquerade:`/`expose:` policy. This is the TankOS
  router/firewall posture; on the wedge's flat LAN it isn't needed.

The intent contract is stable across modes: `ip: {:ipam, subnet}` means "an
address from that pool", however frames leave the box.

## Resolution chains (auto-with-override)

For a pod NIC with `ip: {:ipam, subnet}`:

| What | Chain |
|---|---|
| address + prefix len | static IPAM allocation, client `{:tank_pod, pod, nic}` **[built]** |
| gateway | NIC `gateway:` → pool `gateway` **[built]** |
| resolv.conf | pod `network.dns` → pool `dns` → shim address → `Tank.Host.dns()` **[this design]** |
| DNS name | `<pod>.<pool domain \|\| dns origin>` from the allocation's hostname **[built** on the Starfish side; served once the listener exists**]** |

A restarting pod re-allocates and lease affinity returns its previous address
**[built]**. A deleted pod's allocations are released by the reconciler's
level-triggered sweep **[built]**.

## The DNS service

One Starfish DNS listener (store-backed, managed by `Starfish.Servers`):

- **Dynamic zone(s)** bound to IPAM: every pool under its `domain` (or the
  global `origin`), records derived on query from allocations + reservations —
  `hive.tank.internal` exists because the pod does; PTR comes free. No zone
  files, no sync.
- **Upstream forwarding** for everything else via Starfish's hardened stub
  client, so pods need exactly one nameserver line.
- **Binding**: the shim address by default. On Debian this coexists with
  systemd-resolved (which binds 127.0.0.53); TankOS-as-router later adds LAN
  listeners with `Starfish.Servers.put_dns` — more policy, same mechanism.

Boot applies the configured listener declaratively (`Servers.put_dns` with a
stable id); runtime edits through the same API take effect immediately and
survive restarts unless config overrides them at next boot.

## Module map

- `Tank.Net` — the seam (was `Tank.Ipam`): `child_specs/2`, `resolve/1`
  (intents → concrete NICs + resolv.conf defaulting), `reconcile/1` (lease
  GC), `enabled?/0`.
- `Tank.Net.Shim` — ensure the host macvlan shim exists: create-or-adopt link
  over the parent, static IPAM address, idempotent, never torn down on stop
  (level-triggered; recreated/adopted on boot).
- `Tank.Net.Services` — boot actuator: ensure shim → publish its address →
  apply the DNS listener. Child order: store → IPAM → services → reconciler.
- `Starfish.Servers.Supervisor` — the listener tree, on the shared store's
  `[:starfish]` subtree, IPAM injected into dynamic zones.

## Build order

1. `Tank.Net` rename + `config :tank, :net` (pools/reservations subsume the
   interim `:ipam` key).
2. Shim (the one new mechanism) + `Services` boot actuator.
3. DNS listener + the resolv.conf chain (Runtime resolves intents *before*
   `/etc` materialization).
4. e2e under root: pod name resolves through the shim listener.
5. Later, in step with need: `:bridge`/`:routed` + firewalling (TankOS router
   posture), DHCP/RA listeners (same `Servers` mechanism), IPv6 throughout.
