# 0013 — A dedicated `AppProject` for kairos-operator, and the repo's first CI

- Status: Accepted
- Date: 2026-09-10

## Context

Every Application in this repo has run under `project: default` — ArgoCD's
built-in project, which permits every source repository, every destination and
every resource kind. That was proportionate while the repo installed a load
balancer, an ingress and a CSI driver.

ADR 0012 adds `kairos-operator`, and it is a different kind of tenant. Two of
its three CRDs — `NodeOp` and `NodeOpUpgrade` — describe resources that cordon,
drain and reboot a node; the third, `OSArtifact`, is an image-build resource and
touches no node. Its rendered tree is fourteen cluster-scoped objects, including
eight ClusterRoles it did not author. It is also the first app in this repo that
will, later, be driven by a resource somebody commits rather than by a version
bump.

Separately: **this repo has no `.github/` directory.** No CI, no workflow,
nothing. `clusters/<name>/` is a single Kustomize build (ADR 0005), so a
malformed overlay stops every app on that cluster from reconciling — and today
the only thing standing between that and `main` is whether the author
remembered to run `kustomize build` locally. That is a convention, not a
control.

## Problem

Two questions, answered together because the second is what makes the first
worth anything:

1. What should constrain what ArgoCD may sync on the operator's behalf, and
   where should that constraint live?
2. What mechanical check must exist *before* any resource that can reboot a node
   can be merged, given that no such resource exists yet — and how is such a
   check kept from passing merely because it has stopped working?

## Considered Alternatives

### Where the `AppProject` object lives

1. **A separate `base/projects/<name>/` referenced from
   `clusters/<name>/kustomization.yaml` directly.** This is the right answer
   when two or more Applications in different bases share one project, because
   it makes a shared dependency visible instead of hiding it inside one app's
   directory. It is the wrong answer here: the project has exactly one consumer.
   It also puts the enable/disable decision in two files, and ADR 0007's
   rejected alternative 2 already covers listing raw resources alongside
   Applications in root's build — root's children are Applications.
2. **A separate Application that syncs the project.** Worse chicken-and-egg;
   that Application would itself need a project.
3. **Inside `base/kairos-operator/`, alongside the Application.** Chosen.

### Ordering the project before the Application

`AppProject` and `Application` are rendered by the same `clusters/<name>` build
and applied in one root sync. Verified in `gitops-engine`'s
`pkg/sync/sync_tasks.go`: `syncTasks.Less` orders by phase, then wave, then
`kindOrder[kind]`, then `name`. Neither kind is in `kindOrder`, so both score
zero and the tiebreak is the name — which is `kairos-operator` for both objects.
`Less` is false in both directions and `sort.Sort` is not stable, so **the
relative order is undefined.**

1. **`argocd.argoproj.io/sync-wave: "-1"` on the AppProject.** Deterministic —
   wave is compared before kind and name — and safe, since an `AppProject` has
   no health assessment, so the wave completes immediately and cannot stall.
   Rejected on blast radius: it would be the first sync wave in this repo, and
   it would sit in **root's** build, where every other app on the cluster is in
   wave 0. One object's ordering problem would make every app on the cluster
   begin gating on a wave. ADR 0008 chose convergence by retry over gating for
   every ordering edge in this repo, and named the exact failure mode of writing
   an ordering annotation and then reading it back as a guarantee.
2. **Accept the undefined order.** Chosen — see below.

## Decision

### The `AppProject`

`base/kairos-operator/appproject.yaml`, named `kairos-operator`, in `argocd`,
listed in the same `kustomization.yaml` as the Application. The two objects are
enabled and disabled together by one line in
`clusters/<name>/kustomization.yaml`.

`sourceRepos` is one entry, the upstream repository. `destinations` is one
entry, `https://kubernetes.default.svc` / `operator-system`. The two whitelists
are **exactly** the kinds `kustomize build config/default` emits at `v0.2.2`,
counted from the build output:

- cluster-scoped: `Namespace` (1), `CustomResourceDefinition` (3),
  `ClusterRole` (8), `ClusterRoleBinding` (2).
- namespaced: `Service`, `ServiceAccount`, `Deployment`, `Role`, `RoleBinding`
  (1 each).

`namespaceResourceWhitelist` is deliberately not `*/*`, and it is worth being
precise about what that buys, because it is easy to overclaim. **An `AppProject`
constrains what ArgoCD may sync from git. It has no bearing on what the
operator's ServiceAccount does at runtime** — the Jobs, DaemonSets and
ServiceAccounts the operator creates are created by the operator, governed by
the `operator-manager-role` ClusterRole it ships, and are outside the project
entirely. What the whitelist actually stops is a commit under
`base/kairos-operator/`, or a surprising upstream release, creating kinds this
app was never meant to create. Failure is closed: the sync errors until the list
is updated.

### What is on the other side of that line

Having said what the project does not constrain, this ADR has to say what is
unconstrained. `config/rbac/role.yaml` at `v0.2.2` binds one ServiceAccount,
`operator-kairos-operator`, to one cluster-wide ClusterRole. Its notable grants:

| apiGroups | resources | verbs |
|---|---|---|
| `rbac.authorization.k8s.io` | `clusterroles`, `clusterrolebindings`, `roles`, `rolebindings` | create, delete, get, list, patch, update, watch |
| `""` | `nodes` | get, list, patch, update, watch |
| `""` | `secrets` | create, get, list, update, watch |
| `""` | `pods`, `serviceaccounts` | create, delete, get, list, patch, update, watch |
| `apps` | `daemonsets` | create, delete, get, list, patch, update, watch |
| `batch` | `jobs` (+ `jobs/status`) | create, delete, get, list, patch, update, watch |
| `""` | `configmaps`, `namespaces`, `persistentvolumeclaims` | read, and create/delete for PVCs and configmaps |

The first row is the one that matters. **An identity that can create and modify
ClusterRoles and bind them can grant itself more privilege than it holds.**
This is not dormant scaffolding: the reboot path
(`internal/controller/nodeop_controller.go`, `ensureClusterRBAC` /
`ensureNodeOpServiceAccount`) creates a `nodeop-reboot` ClusterRole, a
per-NodeOp ServiceAccount and a per-NodeOp ClusterRoleBinding at runtime, none
of which appear in `config/default`. The second row, `nodes: patch/update`
cluster-wide, is what cordon and uncordon use. The third, `secrets` across every
namespace, belongs to the OSArtifact builder, not to NodeOp — and cannot be
separated from it, because one binary shares one ClusterRole.

No wildcard verb or resource appears anywhere in the role, and there is no
`pods/exec`. That is the honest ceiling: this is a scoped role, and it is still
a role that can escalate itself. Nothing in this repository changes that, and
the AppProject above does not touch it. What bounds it is who can commit a CR
that makes the operator use it — which is the rest of this ADR.

`roles` is absent from the AppProject. A project role mints JWTs for API access;
nothing here consumes one, and each is a credential with a rotation obligation
this repo has already declined to take on (ADR 0010, ADR 0011).

`orphanedResources` is absent, and not merely as an omission. The operator
creates untracked children in `operator-system` — a node-labeler DaemonSet, one
Job per node, and a `kairos-node-labeler` ServiceAccount with its own RBAC.
Orphan monitoring would flag every one of them, permanently, and teach the
reader to ignore the warning.

### Accepting the undefined apply order

On a from-scratch provision, root may apply the Application before its project.
ArgoCD does not reject it. Verified in `argo-cd` v3.4.5,
`controller/appcontroller.go:2608`: a missing project produces an
`InvalidSpecError` *condition* on the Application — the object is created and
kept, and the condition is recomputed on the next reconcile. There is no handler
wiring project creation to an application refresh (the project informer carries
indexers only), so it clears at the ordinary application resync. That is not a
single configured constant: `argocd-application-controller` at v3.4.5 uses
`defaultAppResyncPeriod = 120` seconds plus `defaultAppResyncPeriodJitter = 60`,
so the wait is randomised with a worst case of 180 seconds.

One red Application for at most three minutes on a rebuild, self-clearing, with
no operator action, is the cost. It is cheaper than introducing wave semantics into
root's build for every app on the cluster.

### CI

Two workflows, both new, in a `.github/` directory this change creates.

**`render`** (`kustomize-build` job) — on `pull_request` and on `push` to
`main`. Installs kustomize `v5.8.1` from its GitHub release, verified against
upstream's published checksum, and builds every `clusters/*/` directory. Two
assertions stop a vacuous pass: each cluster's output must contain at least one
`kind: Application`, and at least two clusters must have been built. This is the
check with immediate value — the one thing between a typo in a cluster's
`kustomization.yaml` and every app on that cluster ceasing to reconcile.

**`nodeop-guard`** (`nodeop-guard` job) — on `pull_request`. It enforces two
invariants through `.github/scripts/nodeop_guard.py`:

1. **Cardinality.** A pull request may **introduce or alter** at most one
   `NodeOp`/`NodeOpUpgrade` **document**. Three words are load-bearing.
   *Documents*, because `concurrency` is a per-object field, so two objects
   merged together reconcile independently and reboot two nodes at once — and a
   file-counting check is fooled by one file holding three documents.
   *Introduce or alter*, because counting newly **added files** misses the more
   natural way to add a second node operation: appending a `---` document to a
   file that already exists and is already referenced. The guard therefore reads
   each changed file's pre-image at the merge base, canonicalises the node
   operations on both sides, and counts only what is new or changed. A document
   carried along unchanged by an edit elsewhere in the same file does not count,
   and a rename with no content change does not count.
2. **Selector singularity.** Every introduced or altered `NodeOp`/`NodeOpUpgrade`
   must carry `spec.nodeSelector.matchLabels` with exactly one key,
   `kubernetes.io/hostname`, holding a non-empty string. `matchExpressions` is
   rejected. Verified against the CRD schemas at `v0.2.2`: both kinds expose
   `spec.nodeSelector` as a `metav1.LabelSelector`, and it is **not required** —
   `internal/controller/nodeop_controller.go` targets *all* nodes when it is
   nil, and `NodeOpUpgrade` reaches that same code by constructing a `NodeOp`
   in `nodeopupgrade_controller.go`'s `createNodeOp`, copying the selector
   verbatim, which is why one rule is correct for both kinds. A presence check
   for the string `kubernetes.io/hostname` passes a manifest that also carries a
   second label, or a `matchExpressions` `In` list over three nodes.

Two scoping decisions follow from the same reasoning. The guard **parses every
changed path regardless of its name** — Kustomize reads `resources:` entries by
content, so `reboot-node-a` with no extension renders exactly like a `.yaml`
file — and treats a path that does not parse as YAML as not-YAML unless its name
says otherwise, in which case a parse failure is a hard error. And the diff is
run over the **whole repository**, not a `clusters/` prefix: ArgoCD builds each
cluster with kustomize's root-only load restriction whose root is the repository
checkout, so a manifest parked under `base/` and pulled in by one added line
under `clusters/` renders fine while the added line itself contains no document
to flag.

**The guard self-tests before it is trusted.** No such manifest exists in this
repo, so both checks inspect zero documents and pass — which is
indistinguishable from a guard that has silently stopped detecting. So the job
first runs `.github/scripts/nodeop_guard_selftest.sh`, which builds a throwaway
git repository in a temp directory, replays 21 pull requests through it, asserts
the exit code the guard must return for each, and fails the job if any is wrong.
The cases cover each of the three scoping traps above as well as selector shape.
Confirmed by sabotage: disabling the cardinality branch fails 5 cases, restoring
a filename extension filter fails 1, and removing the pre-image comparison fails
1 — each reporting "the guard is not trustworthy" and exiting non-zero. A green
`nodeop-guard` means "the guard detects, and found nothing", not "nothing was
looked at".

**Both jobs should be required status checks on `main`.** That is a repository
settings change (Settings → Branches → require status checks →
`kustomize-build`, `nodeop-guard` — the job names), it must be done by hand, and
nothing in this repo can do it or verify that it was done.

## Consequences

- `project: default` remains correct for the other eight Applications. This ADR
  does not start a migration; it records why one app needed more.
- An upstream release that adds a kind to `config/default` fails this app's sync
  with a project-permission error until `appproject.yaml` is updated. That is
  the intended behaviour and it will look like a bug the first time it happens.
- On a from-scratch provision, `kairos-operator` may show
  `Application referencing project kairos-operator which does not exist` for up
  to one reconciliation interval. Expected, not a fault.
- The repo now has CI, and every future change is rendered before merge. A
  contributor whose overlay does not build finds out in the pull request rather
  than from a cluster that stopped reconciling.
- `nodeop_guard_selftest.sh` contains the literal strings `kind: NodeOp` and
  `kind: NodeOpUpgrade` in heredocs. These are test inputs for a linter, not
  manifests. They live under `.github/scripts/`, never under `clusters/`; they
  are referenced by no `kustomization.yaml` and reachable by no Application's
  `path`; and they exist as files only inside the `mktemp -d` directory the
  script's `trap` deletes. No cluster can render them and no node can be
  rebooted by them. The alternative is a guard whose correctness nobody can
  demonstrate.
- The guard runs on pull requests only. A direct push to `main` bypasses it,
  which is why the branch protection above is not optional.

## Rationale

The temptation with an `AppProject` is to describe it as a security boundary and
stop there. It is not one for this app: the privileged workloads live on the
operator's side of a line the project cannot see, and the thing that can reboot
a node is a commit, not a sync. Writing that down is most of this ADR's value —
the same value ADR 0008 got from stating plainly that sync waves do not gate.

What follows from being honest about it is the CI. If the real control is
"somebody has to merge a file", then the check that runs at merge time is the
control, and a check nobody can prove still works is not one. The self-test is
the difference between a guard and a green tick.
