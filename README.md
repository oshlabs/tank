# Tank — a proof-of-concept Linx consumer

Tank is **not** part of the Linx package. It is a nested mix app that exists to
validate one thing: that Linx's *public* primitives are sufficient to build the
cross-subsystem composite that, by design, can only live in a consumer —
"this container should exist, with this network, in its own namespace, and be
restarted if it crashes."

That object spans `Linx.Process` and `Linx.Netlink.Rtnl`, so it cannot live in
Linx itself. Tank builds it, and in doing so acts as the **acceptance test** for
the Linx reconcile work: if Tank ever needs something Linx doesn't expose,
that's a real gap in the primitives — surfaced early, here.

## Public API only, by construction

Tank depends on Linx via a *path* dependency (`{:linx, path: ".."}`), as a
separate OTP application. It therefore reaches **only Linx's public API**,
never its internals — the boundary is enforced structurally, not by
discipline. Lifting Tank into its own repository later is:

```
git mv tank ../tank
# then change tank/mix.exs:  {:linx, path: ".."}  ->  {:linx, "~> x.y"}
```

…and nothing else.

## What it composes (`Tank.Container`)

1. **`Linx.Process`** spawns the workload into a fresh network namespace and
   parks it at the `:ready` checkpoint.
2. **`Linx.Netlink.Rtnl` + `Rtnl.Reconcile`** configure that namespace from the
   host while the workload waits — bring interfaces up, converge the desired
   addresses and routes — then the workload `proceed`s.
3. **OTP supervision** restarts the whole composite on an abnormal exit, with a
   brand-new namespace reconfigured from scratch (lifetime = ownership: the
   network dies and is reborn with the container).

```elixir
children = [
  {Tank.Container,
   %{argv: ["/usr/bin/myd"], namespaces: [:net],
     network: %{up: ["lo"], addresses: [{"lo", "10.0.0.1", 32}]},
     owner: MyApp.Events}}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Running

The composite needs real namespaces, so the tests need root:

```
mix deps.get
sudo ./sudotest.sh          # = sudo mix test --include integration
```

## Scope

A proof of concept, not a finished orchestrator: one container, network on
existing interfaces (loopback, or a parent already moved in). veth-pair
plumbing, multi-container coordination, and a persisted desired-state store are
the natural next steps once Tank graduates out of the Linx tree.
