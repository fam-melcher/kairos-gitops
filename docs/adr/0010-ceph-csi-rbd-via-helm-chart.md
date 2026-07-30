# 0010 — ceph-csi-rbd via the upstream Helm chart

- Status: Accepted
- Date: 2026-07-30

## Context

ADR 0004 established that this repo installs apps from their project's own
official manifests, and `base/metallb` reinforced it by explicitly rejecting
MetalLB's Helm chart in favour of `config/native` — the chart shipped an
frr-k8s DaemonSet nobody asked for, and omitted the Namespace.

The cluster now needs dynamic PersistentVolumes. Backing store is `mimir`, a
single-node Ceph Reef 18.2.8 cluster on the same L2 segment as all three k3s
nodes, serving pool `k8s-prod-rbd` (replicated 3/2, ~1.2 TiB usable).

## Problem

ceph-csi publishes plain manifests at `deploy/rbd/kubernetes`. Applying the
established pattern would mean pointing an Application at that path. Two facts
make that unworkable at v3.17.0:

1. **Namespace is hardcoded.** Every namespaced object carries
   `namespace: default` — 11 occurrences across 6 files. ArgoCD injects
   `spec.destination.namespace` only into manifests that omit a namespace, so
   the driver installs into `default` and there is no patch surface to move
   it.
2. **The directory is incomplete.** `csi-rbdplugin.yaml` mounts three
   ConfigMaps — `ceph-config`, `ceph-csi-config`,
   `ceph-csi-encryption-kms-config`. The directory ships only the second, and
   that one containing the literal placeholder `[]`. The DaemonSet cannot
   start until all three exist.

Separately, the driver needs three genuinely per-cluster facts — Ceph fsid,
mon endpoint, RBD pool — that no upstream manifest can carry.

## Considered Alternatives

1. **Sync `deploy/rbd/kubernetes` as-is.** Rejected: lands in `default`, and
   still needs two ConfigMaps invented elsewhere.
2. **Vendor the six manifests into `base/ceph-csi-rbd/upstream/` and run a
   kustomize `namespace:` transformer.** Rejected: it makes this repo the
   owner of another project's manifests, with all 11 hardcoded namespaces
   re-reviewed on every upgrade. It also breaks the property ADR 0004 valued —
   that what is deployed is verifiably what upstream published.
3. **Use the chart, per-cluster values via `source.path` (ADR 0007).**
   Rejected: ADR 0007 exists for per-cluster *resources*, expressed as
   manifests in a cluster directory. Here the difference is values, and Helm
   values are not resources.
4. **Use the chart, per-cluster values inline in the overlay patch.** Chosen.

## Decision

`base/ceph-csi-rbd/application.yaml` uses a Helm source
(`repoURL: https://ceph.github.io/csi-charts`, `chart: ceph-csi-rbd`) and omits
both `spec.source.targetRevision` and `spec.source.helm.values`. The overlay
supplies them as two separate patches, each named for what it patches:
`version-patch.yaml` and `helm-values-patch.yaml`.

Existing overlays put everything in one `version-patch.yaml`, a name that was
accurate under ADR 0001/0002 and stopped being so at ADR 0007, where the same
file also began carrying `source.path`. This overlay does not extend that
misnomer. Renaming the older overlays is deliberately out of scope here —
worth doing as one sweep, not app by app.

This does not overturn ADR 0004. The rule there is that an app is installed
from what its project officially publishes; the chart *is* that, published from
the same repository and tagged in lockstep with the driver (chart 3.17.0 ==
appVersion 3.17.0). `base/metallb` rejected a chart because `config/native`
was the better upstream artifact for that app, not because charts are barred.
Here the manifests are the deficient artifact and the chart is the complete
one.

`syncOptions: CreateNamespace=true` is set — the chart ships no Namespace,
the exact inverse of MetalLB's situation. `managedNamespaceMetadata` carries
`pod-security.kubernetes.io/{enforce,audit,warn}: privileged`, since the
node plugin is privileged with hostPID and bidirectional mount propagation and
there is no upstream `ns.yaml` to carry those labels.

## Consequences

- A third kind of app now exists: version-only (`argocd`, `metallb`),
  content-carrying via `source.path` (`metallb-config`), and values-carrying
  via `helm.values` (`ceph-csi-rbd`). All three keep the base non-deployable
  and the cluster directory complete, which is what ADRs 0001 and 0007 were
  protecting.
- The overlay carries a multi-line YAML string rather than structured fields.
  Kustomize cannot validate its contents; `helm template` against the chart is
  the check, and it was run before merge.
- Upgrades are one `targetRevision` bump, with the chart's own values schema
  as the compatibility surface.
- The `Secret` holding the `client.k8s-prod-rbd` key is created out-of-band
  with `kubectl`. It is the first thing in this cluster not described by this
  repo. Accepted deliberately: the repo has no secret-management tooling, and
  adding sealed-secrets or SOPS is a larger decision than this app should
  force. Revisit when a second secret appears.
- `k8s-dev` gets no ceph-csi app. That cluster is torn down routinely and has
  no decision yet on whether it uses Ceph at all.

## Rationale

The pattern in ADR 0004 is about provenance — deploy what the project
publishes, not a local transcription of it. Both the manifests and the chart
satisfy that. Between them, only one produces a working install without this
repo rewriting upstream content, and rewriting upstream content is the specific
thing ADR 0004 set out to avoid.
