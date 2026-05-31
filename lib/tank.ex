defmodule Tank do
  @moduledoc """
  Tank — a proof-of-concept consumer of Linx.

  Tank exists to answer one question for the declarative-reconciliation work:
  **are Linx's primitives sufficient to build the cross-subsystem composite
  that can only live in a consumer?** ("This container should exist, with this
  network, in its own namespace, and be restarted if it crashes.") That object
  spans `Linx.Process` + `Linx.Netlink.Rtnl`, so by design it cannot live in
  Linx itself — only here.

  It is deliberately a separate mix app with a *path* dependency on Linx, so it
  can reach **only Linx's public API**. If Tank ever needs something Linx
  doesn't expose, that is a real gap in the primitives, surfaced early. Lifting
  Tank into its own repo is a `git mv` plus a one-line dependency change.

  ## What it composes

  `Tank.Runtime` ties three Linx mechanisms into one supervised unit:

    1. **`Linx.Process`** spawns the workload into a fresh network namespace
       and parks it at the `:ready` checkpoint.
    2. **`Linx.Netlink.Rtnl` + `Rtnl.Reconcile`** configure that namespace from
       the host while the workload waits — bring interfaces up, converge the
       desired addresses and routes.
    3. **OTP supervision** restarts the whole composite on an abnormal exit,
       with a fresh namespace reconfigured from scratch — the self-healing the
       reconcile design calls for, with lifetime = ownership (the network dies
       and is reborn with the container).

  See `Tank.Runtime` for the API and the reconcile design notes in the Linx
  repo (`docs/reconcile/PLAN.md`) for the why.

  ## Status

  This is a proof of concept and the acceptance test for the Linx reconcile
  primitives — not a finished orchestrator. It manages a single container's
  network on existing interfaces (loopback, or a parent already moved in); veth
  pair plumbing, multi-container coordination, and a desired-state store are
  the natural next steps once it graduates out of the Linx tree.
  """
end
