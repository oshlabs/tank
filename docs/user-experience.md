# What the User Sees

This is the **entire** surface a TankOS owner ever touches. Everything in
`cluster-orchestration.md` — leases, fencing, IPAM, reconcilers, the
provisioning contract — lives *below* this line and never surfaces here.

If a concept on this page leaks an internal mechanism, that's a product bug, not
a feature. The internals are complex on purpose, so that this page can be short.

---

## The whole vocabulary

Three nouns, four verbs, one status.

**Nouns**
- **Node** — a box. You own one or more.
- **App** — something you install from the TappShop (a PBX, Hive, a database-backed
  web app…). Internally an App may be several containers and may pull in services
  like SQL or S3 — but the user just sees "an App."
- **Backup** — a saved copy you can restore.

**Verbs**
- **Install an app** — browse the shop, click Install.
- **Add a node** — plug a box into the network, click Approve.
- **Back up / restore** — one button, or a schedule.
- **Tweak an app** — a few typed settings the app chooses to expose. No files, no YAML.

**One status badge**
```
●     Running — single node      (add nodes for high availability)
●●●   Highly available
```
That badge is the entire high-availability UX. Everything in the deep doc exists
to make those three dots true.

---

## The flows, in plain language

**First boot.** Insert the USB stick, power on, open `http://tank.local`. Name it,
set a password. You now have a one-node Tank.

**Install an app.** Open the shop → pick an app → Install. It downloads and runs.
If it needs a database or storage, that comes with it automatically. It appears
under Apps with a Running badge and an address.

**Go highly available.** Plug a second box into the same network; it shows up as
"New node — Approve?"; click Approve. Add a third. The badge flips to **Highly
available**. Apps spread across the boxes and your data starts replicating — you
did nothing but click Approve. (For a two-box home setup, the third can be a small
low-power "witness" device — the UI just suggests it.)

**When a box dies.** Apps keep running; failover happens invisibly. The badge may
read "2 of 3 nodes." Replace the dead box, plug a new one in, Approve — back to
full HA.

**Back up.** Settings → Backup → pick a destination (a USB drive, an external S3)
→ Back up now, or schedule it. Restore is: pick a backup, confirm.

---

## Hidden by default, revealed in Advanced mode

The default view shows **nothing a non-technical owner wouldn't understand** — the
nouns, verbs, and badge above, plus an app's address if it has one (a URL isn't
scary). It's opinionated and jargon-free on purpose.

An **Advanced mode** (a toggle, off by default) reveals the full machinery for the
experienced engineer — both the *observability* and the *knobs*:

- **See:** internal addresses & endpoints, DNS, which node holds each role, node
  health, lease/quorum state, the reconciler's view, the dependency graph.
- **Change:** scaling preferences, address ranges, lease timings, per-app typed
  settings, network policy.

So the same system is a one-badge appliance for the SMB owner *and* a
fully-instrumented cluster for the engineer — it just doesn't show the second face
unless asked. (The operator never assembles containers — composition lives in the
Tapp, authored upstream.)

---

## The MVP slice (build this first)

**One node, the web UI, the shop — install and run a single container, see it
running with an address.** No clustering, no HA, no provisioning.

This proves the whole product *feel* — "Proxmox for containers." Every mechanism
in `cluster-orchestration.md` then bolts in *underneath* this screen without
changing it: the user's view doesn't change when you go from one node to three —
the badge just gains dots.
