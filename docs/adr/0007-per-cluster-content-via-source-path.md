# 0007 — Per-cluster *content* via a patched `source.path`

- Status: Accepted
- Date: 2026-07-26

## Context

Every overlay in this repo so far patches exactly one scalar: an app's
version. `base/<app>/application.yaml` omits `spec.source.targetRevision`,
and `clusters/<name>/apps/<app>/version-patch.yaml` supplies it (ADR 0001,
ADR 0002).

MetalLB breaks that pattern. Its `IPAddressPool` holds an address range that
is genuinely different per cluster — `192.168.1.12/32` on `k8s-dev`,
`192.168.30.3/32` on `k8s-prod`, on separate network segments. This is not a
small override of a shared default; the two share nothing.

Gateway API's `Gateway` will hit the same wall next, with per-cluster listener
hostnames.

## Problem

How does a per-cluster *resource* — not a per-cluster value — get expressed,
without breaking the shared-base shape ADRs 0001/0002/0005 established?

## Considered Alternatives

1. **Patch the resource's fields per cluster.** Keep one shared
   `IPAddressPool` in `base/` and patch `spec.addresses` per cluster.
   Rejected: `addresses` is a list, and ADR 0002 explicitly flags list
   mutation as the case where strategic merge falls down and JSON6902 index
   paths would be needed — the exact fragility that ADR chose to avoid. It
   also means the base carries a placeholder address that is correct for no
   cluster, which is pure ceremony.
2. **Render the CRs directly into root's build.** List
   `metallb-config/ipaddresspool.yaml` as a resource in
   `clusters/<name>/kustomization.yaml` alongside the Applications. Rejected:
   ADR 0005 states root's children are real Applications; raw cluster
   resources would be a third category, and they would be owned by root's own
   Application, whose destination namespace is `argocd`.
3. **Patch `spec.source.path` per cluster.** Chosen.

## Decision

For apps whose configuration is per-cluster content rather than per-cluster
values, `base/<app>/application.yaml` omits **both**
`spec.source.targetRevision` and `spec.source.path`. The overlay's
`version-patch.yaml` supplies both:

```yaml
spec:
  source:
    targetRevision: HEAD
    path: clusters/k8s-dev/apps/metallb-config/resources
```

The referenced `resources/` directory holds that cluster's actual manifests,
sitting inside that cluster's own directory.

`spec.source.repoURL` in the base becomes this repo's own URL
(`https://github.com/fam-melcher/kairos-gitops`) — the first place this repo
references itself. Root already targets it from the outside; this is the same
fact, expressed from the inside.

`targetRevision: HEAD`, matching the root Application that `kairos-configs`
bootstraps (`configs/roles/16-argocd.yaml`). Not a tag, and not `main`: a
sub-Application pinned to a tag while its parent follows `HEAD` gives two
different views of the same repo within one cluster.

## Consequences

- Still inside ADR 0002. `path` is a scalar under `spec.source`, matched by
  resource identity — structurally identical to the existing `targetRevision`
  patch, just one field more.
- Still inside ADR 0001. The base remains non-deployable on its own, now for
  two reasons instead of one.
- Still inside ADR 0005. Root's children remain real Applications.
- `clusters/<name>/` keeps being the complete picture of what a cluster runs —
  now including the literal resources, not just the version pins. This is the
  property ADR 0001 chose cluster-grouping for in the first place.
- Two kinds of app now exist: version-only (`argocd`, `metallb`) and
  content-carrying (`metallb-config`). The difference is visible in the
  overlay's patch — one field or two.
- Auditing "what address does each cluster use" means reading each cluster's
  `resources/` directory. Same trade-off ADR 0001 already accepted.
- Applications that reference this repo will re-sync on any commit to `HEAD`
  that touches their `path`, independently of the root Application's own
  reconcile.

## Rationale

The alternative that keeps everything in `base/` requires patching a list, and
ADR 0002 already decided that this repo does not do that. Once the values
genuinely differ rather than merely varying, the honest expression is a
different file, not a patched shared one — and `source.path` is how ArgoCD
already lets one Application definition point at different content.
