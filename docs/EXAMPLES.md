# Tank by example

Tank is a declarative container orchestrator for the BEAM, built entirely on
[Linx](../../README.md). You describe the pods that should run — their image,
network, resources, and restart policy — as plain Elixir data; Tank persists
that desired state in a Khepri store, and a reconcile loop converges the machine
toward it, keeping it there across drift, crashes, and reboots.

It is the Kubernetes shape collapsed to a single node: **you never imperatively
start a container.** You state intent with `Tank.apply/1`, and the loop makes
reality match — start, restart-with-backoff, stop — until you change the intent.
Tank is deliberately opinionated (macvlan networking, one consistent state tree)
so an embedded device — its home is TankOS, a Nerves device OS — gets a runtime
rather than a kit of parts. It also runs standalone on a plain Linux laptop,
which is where these examples run.

This guide walks the whole surface, from a one-line pod to an interactive shell
inside a running container.

## Contents

- [Running the examples](#running-the-examples)
- [Declarative basics](#declarative-basics) — apply/list/get/delete, images, the OCI command/env merge
- [Resources](#resources) — volumes, limits, restart policy
- [Networking](#networking) — `:none`, `:host`, macvlan
- [The loop](#the-loop) — how desired state becomes reality
- [Operational config](#operational-config) — data dir, the store, boot seeding
- [Interactive containers](#interactive-containers) — `Tank.exec` and `Tank.attach`
- [Putting it all together](#putting-it-all-together) — a flagship pod, end to end

## Running the examples

Tank creates namespaces, mounts, and network interfaces, so it needs root. From
a checkout, the repo's script starts a privileged `iex`:

    ./sudorun.sh

Everything below is typed at that `iex` prompt. The first time you reference an
image, Tank pulls it from the registry and caches it under the data directory
(see [Operational config](#operational-config)).

## Declarative basics

### Apply, list, get, delete

A pod is declared as a map. The smallest one names a pod and the single
container it runs:

    Tank.apply(%{
      name: "web",
      containers: [%{name: "app", image: "nginx:1.27"}]
    })

`apply/1` writes the desired state and returns `:ok`; the reconciler brings the
pod up. The other verbs read and remove desired state:

    Tank.list()        #=> [%Tank.Pod{name: "web", ...}]
    Tank.get("web")    #=> {:ok, %Tank.Pod{...}}
    Tank.delete("web") #=> :ok  (the reconciler tears the pod down)

`apply/1` is create-or-replace: applying the same name again with new fields
updates the pod in place.

### Specs are validated structs

The map form is sugar. `apply/1` validates it into a `%Tank.Pod{}` (with
`%Tank.Container{}` and friends), and you can pass the struct directly:

    pod = Tank.Pod.new!(%{
      name: "web",
      containers: [%{name: "app", image: "nginx:1.27"}]
    })

    Tank.apply(pod)

`Tank.Pod.new/1` returns `{:ok, pod}` / `{:error, reason}`; `new!/1` raises on
invalid input. Validation is strict — an unknown field, a duplicate container
name, or a mount referencing an undefined volume is rejected up front rather
than failing at bring-up.

### Image references

`image:` is an OCI/Docker reference, resolved against the registry with
multi-arch selection for the host:

    %{name: "app", image: "debian:13"}
    %{name: "app", image: "ghcr.io/acme/api:1.4.2"}

For a rootfs you have already assembled on disk, the `{:rootfs, path}` escape
hatch skips the registry entirely:

    %{name: "app", image: {:rootfs, "/srv/images/custom"}}

### Command, args, env, working directory

By default a container runs the image's own entrypoint. You can override any
part of it, following the OCI rules:

    %{
      name: "app",
      image: "debian:13",
      command: ["/usr/bin/myserver"],   # overrides the image Entrypoint
      args: ["--port", "8080"],         # overrides the image Cmd
      env: %{"LOG_LEVEL" => "debug"},   # merged over the image Env
      working_dir: "/srv"               # overrides the image WorkingDir
    }

The resolution mirrors the OCI spec: argv is `command ++ args` when `command`
is given (the image `Cmd` is dropped); otherwise it is the image `Entrypoint`
followed by `args` (or the image `Cmd` if you give no `args`). `env` is the
image's environment with your map merged over it. `working_dir` falls back to
the image's `WorkingDir`, then `/`.

## Resources

### Volumes and mounts

Volumes are declared at the pod level and mounted into containers by name. A
**managed** volume is allocated by Tank under its data directory; a `{:host,
path}` volume bind-mounts an existing host directory (the escape hatch):

    Tank.apply(%{
      name: "db",
      volumes: [
        %{name: "data"},                              # managed (default)
        %{name: "config", source: {:host, "/etc/db"}} # host path
      ],
      containers: [
        %{
          name: "postgres",
          image: "postgres:17",
          mounts: [
            %{volume: "data", path: "/var/lib/postgresql/data"},
            %{volume: "config", path: "/etc/postgresql", read_only: true}
          ]
        }
      ]
    })

A mount's `path` is always absolute — it is the mountpoint *inside* the
container. Every mount must reference a volume the pod defines, or `apply/1`
rejects the spec.

### Limits

Per-container cgroup v2 limits are a map:

    %{
      name: "app",
      image: "nginx:1.27",
      limits: %{
        memory: 256 * 1024 * 1024,   # bytes
        pids: 100,                   # max processes
        cpu: {50_000, 100_000}       # {quota_us, period_us} -> ~0.5 CPU
      }
    }

`cpu: {quota, period}` is the cgroup CPU bandwidth pair: the container may use
`quota` microseconds of CPU per `period` microseconds. `{50_000, 100_000}` is
half a core; `{200_000, 100_000}` is two cores.

### Restart policy

The pod's `restart:` is owned by the reconciler:

    %{name: "web", restart: :always, containers: [...]}      # default
    %{name: "batch", restart: :on_failure, containers: [...]}
    %{name: "oneshot", restart: :never, containers: [...]}

  * `:always` — restart whenever the container stops, for any reason.
  * `:on_failure` — restart only on a non-zero exit or a signal.
  * `:never` — run once; never restart.

Restarts use exponential backoff: `min(base · 2ⁿ, cap)`, reset after the
container has run stably for a while. See [The loop](#the-loop).

## Networking

A pod is one network namespace. `network:` describes it. The two whole-netns
shortcuts are atoms:

    %{name: "web", network: :none, containers: [...]}   # isolated; loopback only
    %{name: "web", network: :host, containers: [...]}   # share the host's network

`:none` is the default.

### macvlan

The opinionated v1 model gives a container its own MAC and a real LAN IP via
**macvlan** on a host uplink — no bridge, no NAT. Describe one or more NICs:

    Tank.apply(%{
      name: "web",
      network: %{
        nics: [
          %{name: "eth0", parent: "eth0", ip: {"10.0.0.5", 24}, gateway: "10.0.0.1"}
        ],
        dns: ["10.0.0.1"]
      },
      containers: [%{name: "app", image: "nginx:1.27"}]
    })

  * `parent:` is the host uplink the macvlan attaches to. It defaults to
    `:auto`, which resolves to the configured host uplink (see
    [Operational config](#operational-config)) — so you usually omit it.
  * `ip:` is `{address, prefix}` — a static IPv4 address and CIDR prefix.
  * `gateway:` adds a default route (optional).
  * `dns:` is pod-level — it becomes the container's `/etc/resolv.conf`. Omit it
    and the container inherits the host's DNS.

A pod's netns can hold several NICs, e.g. one per uplink:

    network: %{
      nics: [
        %{name: "eth0", parent: "eth0", ip: {"10.0.0.5", 24}, gateway: "10.0.0.1"},
        %{name: "eth1", parent: "eth1", ip: {"192.168.5.5", 24}}
      ],
      dns: ["10.0.0.1"]
    }

Loopback is always raised. (macvlan is commonly refused on Wi-Fi uplinks; on
Wi-Fi-only devices use `:host`.)

## The loop

Tank is level-triggered: you change desired state, the reconciler converges
reality toward it. There is no imperative "start" — applying a pod *is*
starting it.

    Tank.apply(%{
      name: "ticker",
      restart: :always,
      containers: [%{name: "c", image: "alpine:latest",
                     command: ["/bin/sh", "-c", "while true; do date; sleep 1; done"]}]
    })

Within moments the container is running. If its process exits or crashes, the
reconciler restarts it per the pod's policy, backing off exponentially if it
keeps failing — `min(base · 2ⁿ, cap)` — and resetting the backoff once it has
run stably. Delete the desired state and the pod is gone:

    Tank.delete("ticker")

This is the Kubernetes shape, collapsed to one node: desired state is the
source of truth, and a control loop is the only thing that touches reality.

## Operational config

Distinct from *what* runs (desired state) is *where Tank keeps its stuff*
(operational config) — plain application config in `config/runtime.exs`.

### Data directory

    config :tank, data_dir: "/var/lib/tank"

Images, managed volumes, and per-pod scratch live here. Standalone Tank
defaults this to a per-user cache directory (override with the `TANK_DATA_DIR`
environment variable).

### The store

Desired state lives in a Khepri (Raft-backed) store. Tank either boots a
default store or attaches to one a consumer already runs:

    # Standalone: Tank boots and owns a store under data_dir.
    config :tank, :store, data_dir: "/var/lib/tank/khepri"

    # Bring-your-own: attach to a store the host already started, by name.
    config :tank, :store, store_id: :my_store

With `:data_dir` set, Tank owns the store's lifecycle; with only `:store_id`,
Tank assumes the consumer manages it. This is the "bring-your-own-or-boot-a-
default" pattern — a device OS owns the store; a laptop lets Tank boot one.

### Seeding pods at boot

Pods listed in config are written to the store **create-if-absent** on a fresh
machine, so the boot seed never clobbers state you changed at runtime:

    config :tank, pods: [
      %{name: "web", containers: [%{name: "app", image: "nginx:1.27"}]}
    ]

Config is a *starting point*, not a live mirror: removing a pod is
`Tank.delete/1`, not deleting it from config. Runtime changes persist across
reboots.

### Host network facts

Tank reads two facts about the *host's* network — the uplink a macvlan attaches
to (resolving `parent: :auto`) and the DNS servers a container inherits — through
a swappable adapter, so it shares them without owning host networking. The
default adapter reads them from config:

    config :tank, Tank.Host.Static,
      uplink: "eth0",
      dns: ["10.0.0.1"]

With this set, a NIC can omit `parent:` (it defaults to `:auto`) and a pod can
omit `dns:` — both fall back to these host facts. A consumer that manages host
networking itself (e.g. a Nerves device reading VintageNet) points
`config :tank, host: MyHostAdapter` at its own `Tank.Host` implementation; Tank
core never depends on it.

## Interactive containers

A running container is not a black box — you can run commands inside it.

### `Tank.exec` — a shell in a running container

`Tank.exec/3` is the `docker exec -it` model: the pod's main process keeps
doing its job while you run a **second** process — typically a shell — that
enters the container's namespaces with a PTY. Leaving the shell does not stop
the container.

Start a pod whose main process is a long-lived keepalive, then open a shell in
it:

    Tank.apply(%{
      name: "shell",
      containers: [%{name: "app", image: "debian:13",
                     command: ["/bin/sleep", "infinity"]}]
    })

    Tank.exec("shell", ["/bin/bash"])

You get an interactive bash prompt **inside** the container — its own
filesystem, its own isolated process tree:

    # cat /etc/os-release
    PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
    ...
    # ps -e -o pid,comm
        PID COMMAND
          1 sleep
          7 bash
         13 ps
    # exit

The container's PID namespace is its own: the pod's keepalive is pid 1, and the
bash you exec'd is a fresh process beside it. Typing `exit` ends only the bash —
`sleep infinity` keeps running. Exec again whenever you like, and you can run
several exec sessions into the same pod at once (each from its own `iex`).

`Tank.exec/3` returns the session's terminal result:

    Tank.exec("shell", ["/bin/sh", "-c", "echo hi; exit 3"])
    #=> {:ok, {:exited, 3}}

You can also leave an interactive session **without** ending the command:
press the detach sequence — `Ctrl-P` `Ctrl-Q` (docker's default) — and the call
returns `{:ok, :detached}`, restoring your terminal while the command keeps
running inside the container:

    Tank.exec("shell", ["/bin/bash"])
    # ... look around, then press Ctrl-P Ctrl-Q ...
    #=> {:ok, :detached}

The exec session inherits the **container's** environment — the image's `Env`
(so `PATH` resolves against the rootfs) plus a default `TERM` for a usable
shell — and starts in the container's working directory. Override per call:

    Tank.exec("shell", ["/bin/bash"], cwd: "/tmp", env: ["DEBUG=1"])

`:env` entries are merged over the container's own environment (last writer per
key wins); `:cwd` overrides the starting directory.

Because the PTY is wired through your terminal, call `Tank.exec/3` straight
from `iex` (or anywhere the caller owns a terminal) — it blocks for the life of
the session and restores your terminal cleanly when the command exits, even on
a crash.

### `Tank.attach` — taking over the main process

`Tank.attach/1` is the `docker attach` model: instead of running a *second*
process, the container's **main** process *is* the interactive program, and you
take over its terminal. Declare the container with `tty: true` so its main
process runs on a PTY:

    Tank.apply(%{
      name: "console",
      restart: :always,
      containers: [%{name: "sh", image: "debian:13",
                     command: ["/bin/bash"], tty: true}]
    })

    Tank.attach("console")

Your terminal becomes the container's bash. Since ending that bash would stop
the whole pod, leave *without* killing it by pressing the detach sequence —
`Ctrl-P` `Ctrl-Q` — and re-attach whenever you like:

    Tank.attach("console")
    # ... work in the shell, then press Ctrl-P Ctrl-Q ...
    #=> {:ok, :detached}

    Tank.attach("console")   # back in the same bash, still running

If you *do* end the main process (type `exit`, or it crashes), `attach/1`
returns its terminal result and the pod stops — at which point the reconciler
applies the pod's `restart` policy. With `restart: :always`, a fresh bash comes
right back up.

    Tank.attach("console")
    # ... type `exit` ...
    #=> {:ok, {:exited, 0}}

`attach/1` returns `{:error, :not_a_tty}` if the container wasn't declared
`tty: true`, and `{:error, :not_running}` if the pod has no live workload.

**`exec` vs `attach` at a glance:** use `exec` to get a shell *beside* a
running service (the common case — the service keeps serving); use `attach`
when the container *is* the interactive program and you want its own terminal.

## Putting it all together

A realistic pod brings the pieces together — a real LAN IP via macvlan, a
managed volume, resource limits, and a restart policy — declared as one map:

    Tank.apply(%{
      name: "api",
      restart: :always,
      network: %{
        nics: [%{name: "eth0", parent: "eth0", ip: {"10.0.0.20", 24}, gateway: "10.0.0.1"}],
        dns: ["10.0.0.1"]
      },
      volumes: [%{name: "state"}],
      containers: [
        %{
          name: "app",
          image: "ghcr.io/acme/api:1.4.2",
          env: %{"PORT" => "8080"},
          mounts: [%{volume: "state", path: "/var/lib/app"}],
          limits: %{memory: 512 * 1024 * 1024, pids: 200, cpu: {100_000, 100_000}}
        }
      ]
    })

That single call pulls the image, builds the rootfs, raises a macvlan interface
holding `10.0.0.20` on the LAN, mounts the volume, applies the cgroup limits,
and starts the container — then keeps it running, restarting with backoff if it
crashes. To look inside while it serves, exec a shell beside it:

    Tank.exec("api", ["/bin/sh"])

And the interactive flagship — a container that *is* a shell, which you can
leave and return to without stopping it:

    Tank.apply(%{
      name: "console",
      restart: :always,
      containers: [%{name: "sh", image: "debian:13", command: ["/bin/bash"], tty: true}]
    })

    Tank.attach("console")     # your terminal becomes the container's bash
    # ... press Ctrl-P Ctrl-Q to detach, leaving it running ...
    Tank.attach("console")     # right back where you were

    Tank.delete("console")     # and it's gone

Everything above is desired state in Khepri with a loop converging to it. No
imperative start, stop, or restart anywhere — just intent, and a machine that
makes it true. That is the whole of Tank.
