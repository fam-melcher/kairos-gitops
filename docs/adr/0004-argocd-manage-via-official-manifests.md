# 0004 — Manage ArgoCD via its own official manifests, not argo-helm

- Status: Accepted
- Date: 2026-07-25

## Context

[ADR 0003](0003-serverside-apply-remove-retirement-hook.md) added
`ServerSideApply=true` to `argocd-release` but left its source as the
`argo-cd` chart from the separate `argo-helm` community project.
`kairos-configs`'s bootstrap (ADR 0017 there) applies ArgoCD's own
official `manifests/install.yaml` directly. These are two different
packaging projects for the same application, maintained separately, and
they are not guaranteed to wire up every component identically.

Confirmed in practice on a fresh reinstall: after bootstrap,
`argocd-release` reconciled a new `argocd-redis` ReplicaSet whose
`secret-init` container ran under the `default` ServiceAccount and
failed — `secrets is forbidden: User
"system:serviceaccount:argocd:default" cannot create resource "secrets"
... in the namespace "argocd"`. Checked directly: ArgoCD's own
`manifests/base/redis/` ships a dedicated `argocd-redis-sa.yaml` +
`argocd-redis-role.yaml` + `argocd-redis-rolebinding.yaml` for exactly
this. The `argo-helm` chart's rendering of the same component didn't
match.

ArgoCD's own documented self-management example
(https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
uses `path: manifests/cluster-install` in `argoproj/argo-cd` — a
Kustomize directory (`namespace-install` + `cluster-rbac` + `crds`), not
the `argo-helm` chart. Verified directly:
`kustomize build manifests/cluster-install` at tag `v3.4.5` produces
byte-identical output to `manifests/install.yaml` (the file
`kairos-configs`'s bootstrap applies) except for one auto-generated
header comment.

## Problem

Given bootstrap and self-management need to agree on what ArgoCD
actually looks like, which source should `argocd-release` use?

## Decision

`argocd-release`'s source becomes `argoproj/argo-cd`'s own
`manifests/cluster-install` (Kustomize), pinned to `v3.4.5` — the same
tag `kairos-configs`'s bootstrap applies. `version-patch.yaml` in each
cluster overlay now patches `targetRevision` to a real ArgoCD git tag
instead of an `argo-helm` chart version.

## Consequences

- Bootstrap and self-management are the same packaging project, at the
  same version, from the moment hand-off happens — no seam for
  component-wiring differences to hide in.
- Bumping ArgoCD's version means updating one tag in one place per
  cluster (`version-patch.yaml`), matching what `kairos-configs` must
  also update in lockstep (ADR 0017 there) — a deliberate, reviewed pair
  of changes, same posture as every other pinned version in either repo.
- No more `helm.releaseName`/chart-specific fields to reason about.

## Rationale

The redis RBAC failure wasn't a bug in either packaging project on its
own — it's what happens when two independently-maintained renderings of
the same application disagree about one component's wiring. Matching
ArgoCD's own documented self-management pattern exactly removes the
disagreement instead of patching around whichever component breaks next.
