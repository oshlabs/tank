# Changelog

All notable changes to Tank are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The web face: `lib/tank_web`** — a Phoenix LiveView admin UI inside the
  tank app (one OTP application; the stock `app`/`app_web` layout). Opt-in:
  `config :tank, :web, enabled: true` or `TANK_WEB=1`; absent, Tank boots
  headless exactly as before. Screens: pod list (live status, apply/delete),
  pod detail — status header with IPAM addresses, streaming CPU/mem/RX/TX
  stat tiles and charts, live log viewer, in-browser terminal (exec a shell
  or attach, over `Tank.Console`), spec view — plus read-only networks and
  system pages. Renders Gooey (the shared design system; tank theme).
  Dev: `mix phx.server` (UI-only) or `./sudoweb.sh` (real containers; builds
  into `_build-sudo` so root and user builds never collide).
- **Domain plumbing under the UI** (all headless-safe): `Tank.Events`
  (`:pods` + `{:stats, pod}` topics); observed pod status kept and merged —
  `Tank.status/0,1` (incl. `last_exit`), `Tank.restart/1`; `Tank.Stats`
  (2s sampler: cgroup cpu/mem/pids + per-netns interface counters; ETS ring
  history raw 10min + coarse 4h; `Tank.stats/1,2`) — every pod now gets an
  accounting cgroup, limits or not; `Tank.Console` (exec/attach as
  byte-stream sessions for non-terminal consumers, with attach guard and
  log tee); `Tank.Store.Web` (`[:tank_web]` subtree seam).
- Pods get their own hostname: bring-up sets the UTS `kernel.hostname` to
  the pod name and `/etc/hostname` is materialized (images no longer leak
  their build hostname — debian's "debuerreotype").

### Changed

- **Runtime owner messages are name-attributed**: `{:tank, pod_name, event}`
  (was `{:tank, event_atom, arg}`) so one owner can watch every runtime.
  The reconciler is now every runtime's owner and forwards copies to a
  configured `:owner`.
- Elixir floor raised to `~> 1.19` (gooey requires it).

- **Container log capture.** A non-tty container's stdout/stderr no longer
  vanish into `/dev/null`: a per-pod collector (`Tank.Runtime.Logs`) receives
  them over AF_UNIX `{:connect_unix, _}` stdio — linx connects the sockets
  host-side at spawn time, so nothing socket-shaped ever appears inside the
  container's rootfs — and a `tty: true` container's merged PTY output is teed
  in as the `:tty` stream. Lines are timestamped, stream-tagged, written to
  `<log_dir>/<pod>/<container>.log` with size-based rotation, and broadcast
  live. New API: `Tank.logs/2` (tail, parsed entries) and
  `Tank.Logs.subscribe/1` / `unsubscribe/1` (live `{:tank_logs, pod, entry}`
  messages). Configuration under `config :tank, :logs` (`dir`,
  `max_file_bytes`, `max_files`, `enabled` — set `enabled: false` for the old
  behaviour). Lines cap at 16 KiB (a newline-less stream is force-flushed in
  slices, bounding collector memory). Requires linx newer than 0.2.0
  (host-side `connect_unix`).

## [0.2.0] - 2026-06-06

### Changed

- **All OCI fetching now goes through [Stevedore](https://hex.pm/packages/stevedore).** Tank's
  bespoke registry client is replaced by a thin shim over `Stevedore.Registry` (bearer-token
  handshake, manifest fetch, digest-verified blobs). Image pulls are digest-for-digest equivalent
  — the runtime side (rootfs assembly, caching, offline mode) is unchanged. Depends on
  `stevedore ~> 0.2`.
- **Raised the minimum toolchain to Elixir 1.18 / OTP 28** (was `~> 1.15`): Tank already used the
  built-in `JSON` module (1.18+) and depends on `linx`/`stevedore`, both `~> 1.18`.

### Added

- The registry bearer token is now reused across a pull via Stevedore's token cache
  (`Stevedore.Auth.Cache`): the manifest and every blob share one token instead of re-running the
  `401 → token` handshake per fetch.

## [0.1.0] - 2026-06-04

First public release — pull OCI/Docker images and run them as containers:

- **Image** — pull an image and assemble a runnable root filesystem, with an on-disk
  content-addressed cache (`blobs/`, `rootfs/`, `refs/`) and a no-network `offline:` mode.
- **Runtime** — materialize and run the workload (rootfs pivot, `/proc`·`/dev`·`/sys`, cgroup v2,
  namespaces) via [linx](https://hex.pm/packages/linx).
- **Store** — a tree-structured, Raft-replicated desired-state store.

[0.2.0]: https://github.com/oshlabs/tank/releases/tag/v0.2.0
[0.1.0]: https://github.com/oshlabs/tank/releases/tag/v0.1.0
