# 0008 — Ordering between Applications, without Application health

- Status: Accepted
- Date: 2026-07-26

## Context

MetalLB introduces this repo's first real ordering dependency. Two edges
exist between `metallb` (the upstream install) and `metallb-config` (this
repo's `IPAddressPool` + `L2Advertisement`):

1. **CRDs → CRs.** The CRs cannot be applied before MetalLB's CRDs register.
2. **Webhook serving → CRs.** MetalLB ships
   `ValidatingWebhookConfiguration/metallb-webhook-configuration` with six
   webhooks, **all `failurePolicy: Fail`** (verified by building the artifact),
   covering `ipaddresspools` and `l2advertisements`. Applying the CRs before
   the controller serves that webhook is an admission rejection.

The obvious mechanism is sync waves. It does not work here.

ArgoCD's own documentation records why: the health assessment for
`argoproj.io/Application` was removed in ArgoCD 1.8, and the v3.4.5 docs still
carry the removal notice together with a restoration snippet, noting *"You
might need to restore it if you are using app-of-apps pattern and
orchestrating synchronization using sync waves."* Sync waves gate on health.
An `Application` has no health to gate on. Verified against the shipped
artifact, not just the prose: `manifests/cluster-install` at `v3.4.5` — which
is exactly what `base/argocd` deploys — contains **zero**
`resource.customizations.health.*` entries.

So a wave annotation on an `Application` object influences apply order and
nothing else. It does not wait.

A second, independent trap applies to edge 2. ArgoCD's auto-sync
documentation states that automatic sync *"will not reattempt a sync if the
previous sync attempt against the same commit-SHA and parameters had failed."*
`selfHeal: true` therefore does **not** recover a failed sync — it corrects
drift on a successful one. A webhook rejection is a failure, so nothing would
retry it.

Sequencing the two changes as separate pull requests does not solve this
either. That orders the one-time rollout on the currently-running clusters.
`kairos-configs` re-provisioning a cluster replays the whole repo at once:
root builds `clusters/<name>`, renders every Application, and they sync
concurrently. The repo has to be correct by construction on every rebuild, not
just on the day the change lands.

## Problem

Given sync waves cannot gate on a child Application's readiness, how do
ordering-dependent Applications converge — including on a fresh provision?

## Considered Alternatives

1. **Restore the Application health check** by adding
   `resource.customizations.health.argoproj.io_Application` to `argocd-cm`.
   This is ArgoCD's own documented answer and would make waves work for every
   future app in this repo, not just these two. Rejected *for now* on
   placement, not on merit: `base/argocd`'s source is upstream
   `manifests/cluster-install`, so this repo's overlay patches the
   *Application object*, not ArgoCD's own ConfigMap. Getting the customization
   in requires either a multi-source `base/argocd` or a `kairos-configs`
   bootstrap change. Worth doing; not worth blocking this change on.
2. **Merge the two Applications into one.** When a CR's CRD is part of the
   same sync, ArgoCD orders them and automatically skips the dry run. It would
   remove edge 1 entirely. Not possible here: the install comes from
   `github.com/metallb/metallb` and the CRs come from this repo — two sources,
   one Application, which would need multi-source. Kept as a documented
   fallback.
3. **Sync waves alone.** Rejected — established above that they do not gate.
   Recorded explicitly because the pattern is common enough to be reached for
   by reflex, and because a previous repo by the same author documented a
   three-tier wave scheme, implemented two tiers of it, and relied on operator
   `argocd app wait` commands during bootstrap without the waves ever gating
   anything.
4. **`SkipDryRunOnMissingResource` + an explicit `retry` block.** Chosen.

## Decision

Ordering converges by retry, not by gating.

- **Edge 1** — `SkipDryRunOnMissingResource=true` in `metallb-config`'s
  `syncOptions`. Documented as covering the dry run only.
- **Edge 2** — an explicit `spec.syncPolicy.retry` block on `metallb-config`:
  `limit: 10`, backoff `10s` doubling to a `3m` cap. That is well over ten
  minutes of retry window — enough for image pull, controller start and
  `caBundle` injection on a home LAN.
- **Sync waves are not used at all.** Setting them would document an intent
  the mechanism does not deliver.

`prune: true` and `selfHeal: true` stay as they are on every other app; they
are simply not the mechanism for this.

## Consequences

- On a fresh provision, `metallb-config` may report one or more failed syncs
  before converging. That is expected behaviour, not a fault.
- The Gateway API change inherits the same shape: `SkipDryRunOnMissingResource`
  on the app carrying `GatewayClass`/`Gateway`, and no reliance on waves.
- Envoy Gateway installing before MetalLB is ready is **not** an ordering
  problem. Its Service simply sits `<pending>` and the `Gateway` stays
  un-`Programmed` until an address appears, then self-corrects. No sync
  failure, nothing to gate.
- **This decision rests on an unproven assumption.** No upstream MetalLB or
  ArgoCD documentation describes convergence for the `Fail`-webhook race
  specifically. It must be verified on `k8s-dev` before `k8s-prod`. Fallbacks,
  in order:
  1. One manual `argocd app sync metallb-config` per cluster. The webhooks
     only fire on CREATE/UPDATE of MetalLB CRs, so the exposure is a single
     first sync.
  2. Merge `metallb-config` into `metallb` (alternative 2 above).
  3. Last resort: switch the install to the Helm chart for
     `crds.validationFailurePolicy: Ignore`, accepting permanent loss of
     MetalLB's own CR validation — which ADR 0003's reasoning argues against,
     since it disables a real safety mechanism permanently to smooth a
     one-time first-sync blip.
- Restoring the Application health check (alternative 1) remains the right
  next infrastructure change. It would make wave-based ordering available
  repo-wide and supersede the per-app retry tuning here.

## Rationale

The failure mode this ADR avoids is the one worth naming: writing sync-wave
annotations, reading them back as an ordering guarantee, and never noticing
that the guarantee was never there — because the system converges by retry
anyway and looks like it is working. Stating plainly that convergence is by
retry, and configuring the retry explicitly rather than leaning on defaults,
costs nothing and keeps the mechanism honest.
