# Changelog

All notable changes to Tank are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
