# 0005 — Collapse to the documented two-level App of Apps shape

- Status: Accepted
- Date: 2026-07-25

## Context

[ADR 0001](0001-app-of-apps-per-cluster.md) gave every app a "pointer"
`Application` living directly in `clusters/<name>/`, whose own
`spec.source.path` targeted a nested `clusters/<name>/apps/<app>/`
overlay — three `Application` levels deep for a single app
(`root → argocd (pointer) → argocd-release (real install)`). That shape
was authored before this project adopted a hard rule: verify behavior
against official documentation instead of reasoning from memory.

Checked now, not assumed: ArgoCD's documented App of Apps pattern
(https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern)
is two levels — one parent Application whose rendering directly produces
multiple real child Applications. Quote: *"Declaratively specify one
Argo CD app that consists only of other apps."* The documented example's
child Applications (`guestbook`, `helm-guestbook`, etc.) are each real,
directly-deployed apps — none of them is itself just a pointer wrapping
one further Application. `argocd-release`'s name existed purely because
the pointer and the real Application shared identity (`argocd`/`argocd`,
same apiVersion/kind/namespace) and something had to give the real one a
different name to avoid the collision documented in
[ADR 0004](0004-argocd-manage-via-official-manifests.md)'s predecessor.

Also verified the mechanism that makes removing the pointer possible:
ArgoCD auto-detects the render tool per synced path — a
`kustomization.yaml` present means a Kustomize build, otherwise a
non-recursive plain-manifest directory
(https://argo-cd.readthedocs.io/en/stable/user-guide/tool_detection/,
https://argo-cd.readthedocs.io/en/latest/user-guide/directory/). `root`'s
source path is fixed at `clusters/<name>` (set externally by
`kairos-configs`'s bootstrap). Today that path has no `kustomization.yaml`,
so only files sitting directly in it (the pointers) are visible to
`root` — `apps/<app>/` is invisible to it by design. That is the entire
reason the pointer existed: a thin, top-level, `root`-visible file per
app.

## Problem

Given `root`'s source path can't change, how does removing the
per-app pointer still let `root` see and own each app's real Application
directly?

## Decision

Give each `clusters/<name>/` its own `kustomization.yaml` listing every
enabled app's overlay directory (`resources: [apps/<app>, ...]`).
Presence of that file flips ArgoCD's auto-detection for that path from
"plain directory" to "Kustomize" — `root` now builds it like any other
Kustomize tree, pulling in each app's `apps/<name>/<app>/` overlay
(unchanged: still `base/<app>` + a strategic-merge version patch, ADR
0002), which renders the real Application directly as one of `root`'s
own children. The now-unnecessary pointer file
(`clusters/<name>/<app>.yaml`) and its Application object are removed;
the real Application (`base/<app>/application.yaml`) is renamed back to
its plain name (e.g. `argocd`, not `argocd-release`) since there is no
longer anything for it to collide with.

`base/<app>/` and `clusters/<name>/apps/<app>/` keep the exact shape ADR
0001 already established (shared definition once, per-cluster version
patch) — only the per-cluster top-level pointer file is removed.

## Consequences

- `root`'s children are real Applications again, matching the documented
  pattern exactly — nothing in the tree exists solely to route to
  something else.
- Adding a new app: create `base/<app>/`, create
  `clusters/<name>/apps/<app>/` with its patch, add one line to
  `clusters/<name>/kustomization.yaml`'s `resources:` list. One fewer
  file than ADR 0001's version (no separate pointer file to also create).
- Per-app failure isolation (ADR 0001's original motivation for grouping
  by cluster) is unaffected — each app is still a separately-rendered
  Kustomize resource under `root`, so one app's build failure still
  doesn't block another's sync.
- Applying this to an already-running cluster renames the live
  Application object (`argocd-release` → `argocd`). ArgoCD reconciles the
  existing resources under the new name/tracking-id on the next sync
  rather than recreating them — confirmed compatible with the adoption
  behavior already exercised when the same resources were first adopted
  under `argocd-release`.

## Rationale

The pointer layer solved a real constraint (root's fixed, non-recursive
source path) but did so by adding an `Application` level the documented
pattern doesn't have and doesn't need — Kustomize's own directory
composition already reaches into subdirectories without ArgoCD needing a
separate object per hop. Matching the documented shape removes a level
of indirection instead of maintaining a bespoke one.
