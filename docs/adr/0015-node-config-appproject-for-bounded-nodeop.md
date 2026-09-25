# 0015 — A narrow `node-config` `AppProject`, admitting one reviewed `NodeOp` at a time

- Status: Accepted
- Date: 2026-09-25

## Context

Keycloak (ADR series culminating in the Keycloak/CNPG design under
`opencode/human/`) needs `k8s-prod`'s three server nodes to start k3s with
`--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim` and
`--oidc-groups-claim` pointed at the cluster's own Keycloak. k3s embeds
kube-apiserver in-process (there is no static-pod manifest to patch); the
supported way to add flags is `/etc/rancher/k3s/config.yaml.d/*.yaml`, and on
Kairos the durable owner of that file is a persistent `/oem` cloud-config
(`kairos.io`'s own "Pushing configuration after install" guide). The
documented, operator-native way to deliver a file into `/oem` on a running
node is a `NodeOp`.

ADR 0013 gave `kairos-operator` a project whose whitelist has never included
`NodeOp`. ADR 0014 gave `kairos-upgrade` its own, narrower project — explicitly
*not* `kairos-operator`'s — and that project's whitelist is exactly
`Namespace` + `NodeOpUpgrade`, with `NodeOp` named as deliberately absent:
*"Adding it is an amendment to this ADR, not something a commit under
`upgrades/` can reach."* Neither existing project can sync a bare `NodeOp`
today. This ADR is that amendment, for exactly one purpose: pushing the k3s
OIDC config file.

## Problem

`NodeOp.spec.command` is arbitrary command execution in a privileged,
host-mounted, `hostPID`-adjacent container (ADR 0013's own framing of the same
mechanism `NodeOpUpgrade` uses under the hood). Unlike `NodeOpUpgrade`, a
`NodeOp` has no OS-image version to pin against and no preflight-driven
version check — it is a raw script. Two questions:

1. Does this repo's existing CI guard (`nodeop-guard`, ADR 0013) already bound
   a bare `NodeOp` the same way it bounds `NodeOpUpgrade`, or does allowing
   `NodeOp` need its own new guard logic?
2. What should the project's whitelist and destination be, given `NodeOp` is
   a strictly more general (and more dangerous, by lacking a version-pin
   discipline) mechanism than `NodeOpUpgrade`?

## Considered Alternatives

1. **Widen `kairos-upgrade`'s existing project to also allow `NodeOp`.**
   Rejected on the same reasoning ADR 0014 already gave for not sharing
   `kairos-operator`'s project: a shared project is the union of what both
   consumers need, which is wider than either alone requires. `kairos-upgrade`
   is deliberately `NodeOpUpgrade`-only so that an upgrade round can never
   accidentally also be a bare-command round.
2. **A one-off, manual `kubectl apply` outside git**, matching how the three
   existing hand-applied Secrets are handled (ADR 0010, ADR 0011). Rejected:
   those are static credentials with no execution semantics; a `NodeOp` runs
   a privileged command against node state, which is exactly the class of
   change ADR 0013 built CI enforcement for. Applying one outside git defeats
   that enforcement entirely for the one case it matters most.
3. **A new, narrow `node-config` `AppProject`, one `NodeOp` at a time,
   reviewed like every other change in this repo.** Chosen.

### Does `nodeop-guard` already cover a bare `NodeOp`?

Checked against ADR 0013's own text, not assumed: `nodeop_guard.py`'s bounded
blast-radius rule already treats `NodeOp` and `NodeOpUpgrade` identically —
*"Every introduced or altered `NodeOp`/`NodeOpUpgrade` must either name one
node with `kubernetes.io/hostname`, or be a `NodeOpUpgrade` taking the cluster
one node at a time"* — and the cardinality rule (*"a pull request may
introduce or alter at most one `NodeOp`/`NodeOpUpgrade` document"*) already
counts both kinds together. `nodeop_reachable.py`'s closure walk is generic
over any `Application`'s `spec.source.path`, so a new `node-config`
Application syncing a new directory is inside the closure as soon as it is
listed in `clusters/k8s-prod/kustomization.yaml`, exactly like
`kairos-upgrade`'s `upgrades/` directory was. **No guard-script change is
needed.** What was missing was purely the `AppProject` whitelist — the guard
was always ready for this, ADR 0013 said so directly, and this ADR is the
"amendment" it asked for.

## Decision

### The `node-config` `AppProject` and `Application`

`base/node-config/appproject.yaml`, named `node-config`, alongside a new
`base/node-config/application.yaml` — same shape as `kairos-upgrade`
(ADR 0014), not shared with it.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: node-config
  namespace: argocd
spec:
  description: One reviewed NodeOp at a time, targeting one node each. Nothing else.
  sourceRepos:
    - https://github.com/fam-melcher/kairos-gitops
  destinations:
    - server: https://kubernetes.default.svc
      namespace: kairos-system
  namespaceResourceWhitelist:
    - group: operator.kairos.io
      kind: NodeOp
```

No `Namespace` in the whitelist: `kairos-system` already exists, created and
owned by `kairos-upgrade`'s own `namespace.yaml` (ADR 0014). Two Applications
both tracking the same `Namespace` object is exactly the shared-resource
conflict ADR 0004's ownership rule warns about — `node-config` targets the
namespace as a destination without owning the object.

`destination.namespace` is `kairos-system`, reusing the one namespace this
repo already created for exactly this class of privileged, reviewed
node-level object — not a new namespace whose Pod Security Admission posture
would need re-deciding.

### What this project does *not* relax

Everything ADR 0013 said about an `AppProject`'s actual limits still applies
unchanged: this whitelist constrains what ArgoCD may sync from git. It has no
bearing on what the operator's own `ServiceAccount` does at runtime, and it
does not touch the operator's own cluster-wide `ClusterRole` (unaffected by
this ADR — that grant already exists via `kairos-operator`'s install). What
this project actually bounds is *who can commit a `NodeOp` this repo will
apply* — same framing ADR 0013 used for the operator's own CRDs.

### The synced directory

`clusters/k8s-prod/node-ops/`, same shape as `clusters/k8s-prod/upgrades/`
(ADR 0007/0014): one `kustomization.yaml`, and one file per `NodeOp`, named
for its target and purpose (e.g. `k3s-oidc-config-<hostname>.yaml`) rather
than a generic name — mirroring ADR 0014's "the version fragment is
load-bearing" reasoning, here the hostname fragment is load-bearing, since a
same-named file replacing another node's manifest would be a spec update on
an already-run object, whose behavior upstream documents as unsupported (see
`kairos.io/operator-docs/nodeop`'s "One-off operations" warning, the same
one-shot caveat ADR 0014 already built around for `NodeOpUpgrade`).

Each `NodeOp` is scoped to exactly one node via
`nodeSelector.matchLabels: {kubernetes.io/hostname: <name>}` — the same
selector shape `nodeop-guard` already requires, satisfied by construction, not
by hoping the guard catches a mistake.

`prune: true`, `selfHeal: true` (unlike `kairos-upgrade`'s `selfHeal: false`):
a `NodeOp` that already ran to completion is inert if selfHeal re-creates it
from an unchanged manifest — upstream's one-shot semantics mean a completed
`NodeOp` object sitting in git is not itself hazardous to re-apply verbatim,
unlike `NodeOpUpgrade`'s cascade-delete-on-prune hazard (ADR 0014). The real
protection is still the guard's one-node-at-a-time cardinality rule at merge
time, not `selfHeal`'s setting.

`SkipDryRunOnMissingResource=true` + `retry`, same reasoning as every other
app in this repo touching a CRD that might not be registered yet on a fresh
provision (ADR 0008) — irrelevant here in practice since `kairos-operator`
(which owns the `NodeOp` CRD) is already installed, kept for consistency
with every other content-carrying app rather than as a load-bearing setting.

### Rollout: one `NodeOp` per pull request, three total

`nodeop-guard`'s cardinality rule makes this the only legal shape, not merely
the recommended one: a PR introducing a second `NodeOp` document fails CI.
Three server nodes, three separate PRs, merged and observed one at a time —
the same pacing ADR 0013's quorum-safety reasoning already established for
`NodeOpUpgrade` (never reboot more than one of three etcd members at once),
now enforced for the same reason on a different kind.

### Pre-rollout verification gate

Per `opencode/human/NODE-CHANGES.md` and `RISKS.md` #7: before the *first*
`NodeOp` runs, confirm the Kairos node image's CA trust store actually
contains Let's Encrypt's ISRG Root X1 (or that a JWKS/issuer TLS fetch
otherwise succeeds). A wrong assumption here is discovered by the
one-at-a-time rollout this ADR already mandates — the second and third PRs
are held pending the first node's confirmed-working OIDC login — but it is
worth checking before merging PR one at all, since a failure still costs that
node a reboot to discover.

## Consequences

- `kairos-operator`'s and `kairos-upgrade`'s projects are unchanged by this
  ADR — each keeps exactly the whitelist it had. Three narrow projects now
  exist for three kinds of node-touching object (`OSArtifact`/CRDs,
  `NodeOpUpgrade`, `NodeOp`), which is the same "one project per genuinely
  distinct tenant" reasoning ADR 0013 started, not a new pattern.
- A future second consumer of `node-config` (some other one-off node
  operation, unrelated to Keycloak) is expected and fine — this project's
  whitelist is already general (`NodeOp`, not "OIDC config specifically"),
  unlike `kairos-upgrade`'s `NodeOpUpgrade`-only scope. What would force a
  revisit is a request for something this project's destination/whitelist
  doesn't cover (a different namespace, a different kind).
- Each `NodeOp` here is inherently a one-shot, hand-reviewed script — there is
  no version-pin, no preflight-driven skip logic, and no upstream compat
  guarantee the way `NodeOpUpgrade` has for OS upgrades specifically. Every
  future `NodeOp` merged under this project is exactly as reviewable as its
  diff, and no more — the project bounds *who can sync one*, not *what a
  synced one can safely do to a node*, which ADR 0013 already established is
  not something an `AppProject` can constrain.

## Rationale

ADR 0013 built the guard before any node operation existed, specifically so
that the day one is needed the check is already there rather than being
written under pressure. This ADR is that day: the guard's cardinality and
blast-radius rules already applied to `NodeOp` without modification, and the
only real decision was the project's whitelist and destination — small
enough that getting it wrong is cheap to notice and fix, unlike a guard gap
that silently passes.
</content>
