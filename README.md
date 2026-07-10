# Tank

[![CI](https://github.com/oshlabs/tank/actions/workflows/ci.yml/badge.svg)](https://github.com/oshlabs/tank/actions/workflows/ci.yml)

**A declarative container orchestrator for Linux, built on [Linx](https://hex.pm/packages/linx).**

You describe the *pods* that should run — their image, network, resources, and
restart policy — as plain Elixir data. Tank persists that desired state in an
embedded [Khepri](https://hex.pm/packages/khepri) store, and a reconcile loop
converges the machine toward it, keeping it there across drift, crashes, and
reboots. It is the Kubernetes shape collapsed to a single node: **you never
imperatively start a container** — you state intent with `Tank.apply/1`, and the
loop makes reality match.

Tank is a *consumer* of Linx, not part of it. The cross-subsystem "container"
object — spawn into namespaces, reconcile the network from the host, supervise
the whole thing — is composed entirely from Linx's **public** primitives
(`Linx.Process`, `Linx.Netlink.Rtnl`) plus OTP supervision and a Khepri store.
By design that composite can't live in a primitives library, so it lives here.

> ⚠️ **Early-stage (0.x).** Tank is a working proof of concept maturing into a
> real orchestrator; the API may change between minor releases until 1.0.

## Installation

```elixir
def deps do
  [
    {:tank, "~> 0.1"}
  ]
end
```

### Requirements

- **Linux.** Tank drives kernel namespaces, mounts, and network interfaces, so
  it runs only on Linux and needs privileges to configure them (root, or the
  appropriate capabilities).
- **Erlang/OTP 28 or earlier.** Tank's store uses Khepri, whose Horus dependency
  cannot yet extract stored functions under OTP 29. Run on OTP 28 until that
  support lands upstream.

## A taste

```elixir
# State intent — the reconciler brings the pod up and keeps it up.
Tank.apply(%{
  name: "web",
  restart: :always,
  network: %{
    nics: [%{name: "eth0", parent: "eth0", ip: {"10.0.0.5", 24}, gateway: "10.0.0.1"}],
    dns: ["10.0.0.1"]
  },
  containers: [%{name: "app", image: "nginx:1.27"}]
})

Tank.list()        #=> [%Tank.Pod{name: "web", ...}]
Tank.exec("web", ["/bin/sh"])   # a shell beside the running container
Tank.delete("web") #=> :ok   (the reconciler tears it down)
```


## The web face

Tank ships its own admin UI (`lib/tank_web`, Phoenix LiveView rendering
[Gooey](https://github.com/oshlabs/gooey)): pod list and detail with live
status, streaming stats, a log viewer, and an in-browser terminal
(exec/attach). It is **opt-in** — without `config :tank, :web, enabled: true`
(or `TANK_WEB=1`) Tank runs headless and no web process starts.

Development: `mix phx.server` serves the UI without privileges (pods can't
actuate); `./sudoweb.sh` runs it as root against real containers on
`http://localhost:4400`. Run `mix setup` once for the asset toolchain.

A pod is one network namespace holding one or more containers; `apply/1` is
create-or-replace and validates the map into a `%Tank.Pod{}` up front. The full
surface — images and the OCI command/env merge, volumes and mounts, cgroup
limits, macvlan networking, the reconcile loop, boot seeding, and interactive
`exec`/`attach` — is in **[Tank by example](docs/EXAMPLES.md)**.

## What it composes

For each pod, on every (re)start:

1. **`Linx.Process`** spawns the workload into fresh namespaces and parks it at
   the `:ready` checkpoint.
2. **`Linx.Netlink.Rtnl` + `Rtnl.Reconcile`** configure that namespace from the
   host while the workload waits — raise interfaces, converge the desired
   addresses and routes — then the workload `proceed`s.
3. **OTP supervision + the reconciler** restart the composite on an abnormal
   exit, with a brand-new namespace reconfigured from scratch (lifetime =
   ownership: the network dies and is reborn with the container).

## Running the tests

The reconcile path needs real namespaces, so the integration tests need root:

```sh
mix deps.get
sudo ./sudotest.sh
```

The non-privileged suite runs under a plain `mix test`.

## License

MIT — see [LICENSE](LICENSE).
