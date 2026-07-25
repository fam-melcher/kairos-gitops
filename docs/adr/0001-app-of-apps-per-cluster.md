# 0001 — App-of-apps, grouped by cluster

- Status: Superseded by [0005](0005-collapse-to-two-level-app-of-apps.md) — the per-cluster grouping and base+overlay shape stand; the per-app pointer-file indirection this ADR introduced does not match ArgoCD's documented App of Apps pattern and is removed
- Date: 2026-07-24

## Context

Each cluster provisioned by `kairos-configs` bootstraps its own,
independent ArgoCD instance and stages one root `Application` pointed at
`clusters/<cluster-name>` in this repo. There is no central ArgoCD
control plane spanning multiple clusters — every cluster's ArgoCD only
ever manages itself (`destination.server:
https://kubernetes.default.svc`). That root `Application` does not set
`source.kustomize` or `source.directory`: ArgoCD auto-detects the render
tool per synced path — a `kustomization.yaml` present means a Kustomize
build; otherwise the path is applied as a directory of plain manifests,
non-recursively, unless `directory.recurse: true` is set (it is not).

## Problem

How should this repo be structured so that:

- an app's static definition (chart, repo, sync policy) exists once, not
  once per cluster,
- an app's version can be pinned independently per cluster, so a new
  release can run on one cluster before another,
- an app can be present on one cluster and absent on another,
- a broken configuration for one app does not prevent other apps on the
  same cluster from syncing?

## Considered Alternatives

1. **ApplicationSet** — ArgoCD's built-in primitive for "one definition,
   many targets." Its cluster-discovery generators assume a single
   ArgoCD instance managing multiple registered remote clusters,
   which does not describe this topology: each cluster's ArgoCD only
   ever has one target, itself. A `list` generator can substitute for
   discovery, but a separate `ApplicationSet` would still be needed per
   independent ArgoCD instance, and its `template:` block would still
   duplicate the static app definition across instances rather than
   sharing it. Rejected.
2. **One Kustomize tree per cluster** — a single
   `clusters/<name>/kustomization.yaml` listing every app as a resource,
   with all patches applied in that one tree. Simple, but a build failure
   anywhere in the tree (one bad patch, one app) fails the sync for every
   app in that cluster, not only the broken one. Rejected on the failure
   isolation requirement.
3. **App-of-apps, grouped by app** — a shared `base/<app>/` plus
   `base/<app>/overlays/<cluster>/` per cluster, with a thin pointer file
   per app living directly in `clusters/<name>/`. Satisfies failure
   isolation (each pointer syncs independently) and enable/disable
   (pointer file present or absent). Rejected in favor of option 4: it
   scatters everything running on one cluster across as many
   `base/*/overlays/<cluster>/` locations as there are apps — there is no
   single directory that shows the full picture for one cluster.
4. **App-of-apps, grouped by cluster** — same failure-isolation and
   enable/disable properties as option 3, but each cluster's
   per-app overlays live together under that cluster's own directory
   instead of scattered across every app's directory. Chosen.

## Decision

- `base/<app>/` holds an app's shared, cluster-neutral definition — a
  plain `kustomization.yaml` plus the resource manifest(s). Cluster-
  specific fields (currently: application version) are deliberately
  absent from the base, so it is never a valid, deployable `Application`
  on its own.
- `clusters/<name>/<app>.yaml` is a pointer `Application`: a complete,
  already-rendered manifest (not Kustomize-built) whose own
  `spec.source.path` targets `clusters/<name>/apps/<app>/`. These pointer
  files are the only things living directly at the top level of
  `clusters/<name>/`, which is exactly what the bootstrapped root
  `Application`'s non-recursive directory sync picks up.
- `clusters/<name>/apps/<app>/` holds a small Kustomize overlay: a
  `kustomization.yaml` referencing `base/<app>/` as a resource, plus a
  patch supplying the cluster-specific values the base omits. An app not
  wanted on a given cluster is expressed by this directory (and the
  matching pointer file) simply not existing.
- No change to `kairos-configs` is required by this structure: it
  preserves the `path` value the root `Application` already targets, and
  does not need `directory.recurse: true` — the root sync only ever
  needs to see the pointer files, never the nested overlay directories
  directly.

## Consequences

- `clusters/<name>/` is a complete picture of what a given cluster runs:
  its pointer files and their overlays live together, under one
  directory.
- Auditing "every place app X's overlay is defined across clusters"
  means checking each `clusters/*/apps/X/` location individually — no
  single directory holds all of them. Accepted trade-off for the
  per-cluster visibility above.
- A pointer `Application`'s own overlay build failing only affects that
  one `Application` object; every other pointer in the same cluster
  directory keeps syncing.
- Referencing the shared base from a per-cluster overlay is a
  relative path four directory levels deep
  (`clusters/<name>/apps/<app>/` → `base/<app>/`). Verified working via
  `kustomize build`.
- Adding a new app to a cluster means: create `base/<app>/` if it doesn't
  exist yet, create `clusters/<name>/apps/<app>/` with its patch, create
  `clusters/<name>/<app>.yaml`. Three files/directories, not a single
  flag flip — accepted as the cost of explicit, file-visible
  enable/disable state.

## Rationale

The deciding factor between the two failure-isolated app-of-apps shapes
(options 3 and 4) was which question gets asked more often in practice:
"what does this cluster run" (favors grouping by cluster) versus "how is
this one app configured everywhere" (favors grouping by app). Given the
concrete driver behind per-cluster version pinning — comparing a
candidate release on one cluster against what's already running elsewhere
— the cluster-centric question is the one actually being asked day to
day.
