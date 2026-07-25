# 0003 — ServerSideApply required for self-management; remove the retirement hook

- Status: Accepted
- Date: 2026-07-25

## Context

`kairos-configs` (the provisioning repo) originally bootstrapped ArgoCD
via a persistent k3s `HelmChart` CR. `argocd-release` (this repo) then
took over managing that same Helm release for day-2 (upgrades,
self-management). Since the `HelmChart` CR never went away on its own, a
`PostSync` hook (`base/argocd/retire-bootstrap-helmchart.yaml`) was added
here to delete it once `argocd-release` first synced successfully.

That hook surfaced a chain of failures in practice: a nonexistent image
tag, then a hook that ran forever because `kubectl delete`'s default
`--wait=true` needs `list`/`watch` RBAC the hook's `ClusterRole` didn't
grant, which — since it's a `PostSync` hook — blocked `argocd-release`'s
entire sync operation indefinitely (every resource showed `OutOfSync`
even though nothing had actually changed). A manual recovery attempt
(not ArgoCD's documented `argocd app terminate-op`, improvised instead)
left ArgoCD's own state for the release inconsistent, and the next sync
pruned the entire installation with no bootstrap CR left to recover it.

Checked against ArgoCD's actual documentation instead of assumed: the
official self-management example
(https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
requires `ServerSideApply=true` in `syncOptions` — a requirement this
Application never had — and ArgoCD's own install method is a one-time
`kubectl apply --server-side`, never a persistent second controller.
`kairos-configs`'s bootstrap mechanism is being corrected to match
(ADR 0017 there); once it no longer creates a persistent `HelmChart` CR,
there is nothing left for a retirement hook to retire.

## Problem

Given the provisioning side no longer leaves a persistent competing
controller behind, does this repo still need a retirement mechanism, and
is `argocd-release`'s own sync configuration otherwise correct per
ArgoCD's documented requirements for self-management?

## Decision

- Add `ServerSideApply=true` to `argocd-release`'s `syncOptions`
  (`base/argocd/application.yaml`), matching ArgoCD's documented
  self-management example exactly.
- Delete `base/argocd/retire-bootstrap-helmchart.yaml` and its
  `kustomization.yaml` entry entirely. No hook, no hook RBAC, no hand-off
  timing to reason about — matches `kairos-configs` no longer creating
  anything for this repo to retire.

## Consequences

- One fewer moving part: no `PostSync` hook, no `ClusterRole`/
  `RoleBinding`/`ServiceAccount` for it, no dependency on a specific
  `kubectl` image tag.
- `argocd-release` now matches ArgoCD's own documented self-management
  configuration exactly, not a close-but-incomplete approximation of it.
- If `kairos-configs`'s bootstrap mechanism ever changes back to a
  persistent-controller shape, this decision needs revisiting — the
  retirement-hook problem this ADR closes would return with it.

## Rationale

The retirement hook kept failing in new ways because it was solving a
problem that shouldn't have existed: patching around a provisioning-side
mechanism that didn't match how ArgoCD is documented to be installed and
self-managed. Once the provisioning side is corrected to match ArgoCD's
own documented pattern, the correct fix here is deletion, not hardening.
