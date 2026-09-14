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

### Bounding node operations: a path convention, or the rendered closure

The cheaper design was weighed and is worth writing down, because it is the one
a reader will ask about. Three rules, no rendering, no kustomize in the guard
job, roughly a tenth of the code:

1. a `NodeOp`/`NodeOpUpgrade` document may exist **only** under
   `clusters/*/upgrades/active/`, one document per file — a whole-worktree scan,
   no diff and no render;
2. `clusters/*/upgrades/kustomization.yaml` may gain at most one new `resources:`
   entry per pull request, and every entry must name a file under `active/`,
   never a directory;
3. the selector rule applies to anything under `active/` that is new or altered.

That closes the same bypass: a manifest cannot legally be parked outside
`active/`, and rule 2's "file, not directory" stops the parked-directory trick.
It was rejected for one reason: it is a repository convention the guard enforces,
not a property of what ArgoCD applies. Its guarantee holds only while every
`Application`'s `path` stays inside the shape it assumes, and nothing in it would
notice the day one does not — which is exactly the failure this ADR is written
about, one level up. The closure walk costs more code and a kustomize binary in
the guard job, and in exchange its answer is derived from the same inputs ArgoCD
reads: it needed no change to follow the `kairos-upgrade` application that does
not exist yet, and the same walk now tells the `render` job which roots to build.

The second reason is smaller but real: rule 1 forbids a node operation outside
`active/`, so every legitimate one-off — a `NodeOp` running a command on a node,
which this repository will eventually want — becomes a change to the guard.

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
| `batch` | `jobs` | create, delete, get, list, patch, update, watch |
| `batch` | `jobs/status` | get, patch, update |
| `""` | `configmaps` | create, get, list, watch — **no delete** |
| `""` | `persistentvolumeclaims` | create, delete, get, list, watch |
| `""` | `namespaces` | get, list, watch (read-only) |

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
`main`. It builds every root ArgoCD renders, not a `clusters/*/` glob: the root
list comes from `nodeop_reachable.py --list-roots`, the same closure walk
described below, so each cluster **and** each child `Application`'s own path
(ADR 0007) is built here. Without that, a malformed
`clusters/k8s-prod/apps/gateway/resources/kustomization.yaml` passes `render`
green and surfaces as a node-operation guard error instead — the weaker job
reporting the stronger job's failure. Two assertions stop a vacuous pass: every
cluster root must render at least one `kind: Application`, and there must be at
least two of them. This is the check with immediate value — the one thing
between a typo in a cluster's `kustomization.yaml` and every app on that cluster
ceasing to reconcile.

Both jobs take kustomize from `.github/actions/kustomize`: one pinned version
(`v5.8.1`), one published checksum, one place to bump. Two copies of an install
snippet drift in the field that matters.

**`nodeop-guard`** (`nodeop-guard` job) — on `pull_request`. It runs **two**
checks, because one of them cannot see the whole problem. Both live under
`.github/scripts/` and share their parsing and selector rules through
`nodeop_common.py`, so the two cannot drift on what a node operation is.

*Check one, the diff* (`nodeop_guard.py`) enforces two invariants over what the
pull request changed:

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
   must carry `spec.nodeSelector.matchLabels` naming `kubernetes.io/hostname`
   with a non-empty string, and must not carry `matchExpressions`. The rule is
   "cannot reach more than one node", not "looks like one label":
   `matchLabels` is an AND, so a hostname plus `kairos.io/managed: "true"` —
   the shape the upgrade runbook writes deliberately — can only narrow, and
   rejecting it would mean rejecting the more explicit manifest. What can widen
   is `matchExpressions`: an `In` list over three nodes reads like a selector
   and upgrades a cluster. It is rejected on the key's presence rather than on
   its truthiness, because `matchExpressions: []` is harmless in itself but a
   guard that accepts a key this ADR calls rejected cannot be read from its own
   documentation, and the next edit to an accepted key is not empty. Verified
   against the CRD schemas at `v0.2.2`: both kinds expose `spec.nodeSelector` as
   a `metav1.LabelSelector`, and it is **not required** —
   `internal/controller/nodeop_controller.go` targets *all* nodes when it is
   nil, and `NodeOpUpgrade` reaches that same code by constructing a `NodeOp`
   in `nodeopupgrade_controller.go`'s `createNodeOp`, copying the selector
   verbatim, which is why one rule is correct for both kinds.

Two scoping decisions follow from the same reasoning. The guard **parses every
changed path regardless of its name** — Kustomize reads `resources:` entries by
content, so `reboot-node-a` with no extension renders exactly like a `.yaml`
file — and treats a path that does not parse as YAML as not-YAML unless its name
says otherwise, in which case a parse failure is a hard error. And the diff is
run over the **whole repository**, not a `clusters/` prefix: a manifest parked
under `base/` and pulled in by one added line under `clusters/` renders fine
while the added line itself contains no document to flag.

*Check two, the closure* (`nodeop_reachable.py`) exists because that last
sentence is only half the story. Parking and referencing in **one** pull request
is caught by the unscoped diff. Splitting it across **three** is not: pull
request one adds `base/parked/a.yaml` — one node operation, it passes; pull
request two adds `base/parked/b.yaml` — also one, it passes; pull request three
adds `base/parked` to a `resources:` list. The third changes a single
`kustomization.yaml`, introduces no document, satisfies check one, and reboots
two nodes. Nothing in the repository was unsafe until the line that referenced
it, which is precisely what a diff of content cannot see.

So check two compares sets of *reachable* node operations — the merge base
rendered as one tree, the pull request head as another — and applies the same
two invariants to what is newly reachable. Reachability is walked the way ArgoCD
walks it: the seeds are `clusters/*/`, the paths kairos-configs points each
cluster's root `Application` at; each root is rendered with `kustomize build`
where a kustomization exists and as a plain directory of `.yaml`/`.yml`/`.json`
otherwise (honouring `directory.recurse`); and every rendered `Application`
whose source points back at this repository contributes its own
`spec.source.path` as a further root, recursively. An `upgrades/` directory
synced by a child `Application` is therefore inside the closure before that
directory exists, and an unreferenced file under `base/` is outside it and
counts for nothing until something references it.

The parked shape is a **directory**, not a loose file, and that is kustomize's
doing rather than a choice: the default load restrictor refuses a `resources:`
entry naming a *file* above the kustomization's own root, while a *directory*
carrying its own `kustomization.yaml` is accepted — which is how every overlay
in this repository already reaches `base/`. The self-test pins both halves of
that behaviour so a kustomize upgrade that relaxes it does not quietly widen the
bypass.

Check two **fails closed** on every shape it cannot model *in this repository*,
because a closure that silently misses a root is worse than no closure. Exit 2,
not a pass: an `ApplicationSet` (it generates `Application`s the script does not
expand); a self-referencing `Application` that is pinned to anything but the
default branch, renders through Helm, a config management plugin or a
`sourceHydrator`, or carries `kustomize` patches or components that rewrite
manifests after the point this script read them; a directory holding a
`Chart.yaml`, which makes ArgoCD render it as a chart whose templates are never
read here; a `.jsonnet` file, which ArgoCD evaluates through a VM; a file named
as a manifest that is not text in an encoding ArgoCD reads; a referenced path
that does not exist; and a render or a parse that fails.

Getting that list right meant reading ArgoCD's directory reader rather than
assuming it, because each of its details is a way for a manifest to be applied
and not counted. All four were demonstrated against this repository's real
layout before they were closed, each one merging three node operations in a
single pull request that both checks passed:

- **`kind: List` is unwrapped** before anything else sees it
  (`reposerver/repository/repository.go`, `obj.IsList()` / `obj.EachListItem()`),
  for every source type. Three `NodeOpUpgrade`s inside one List were one
  document of an unrecognised kind. Both guards now flatten Lists.
- **`.jsonnet` is evaluated**, not read: the reader's file pattern is
  `^.*\.(yaml|yml|json|jsonnet)$`. Nothing here can evaluate it, so it is exit 2.
- **A byte-order-marked file is decoded**, not skipped — ArgoCD opens manifests
  through `utfutil.OpenFile(..., utfutil.UTF8)`. A UTF-16 manifest was "binary"
  to both guards and three node operations to the cluster. Both now decode BOMs,
  and a file named as a manifest that decodes in no such encoding is exit 2.
- **A `kind: List` can contain itself** through a YAML alias, and PyYAML builds
  that object without complaint. Expanding it unbounded never returns, and a job
  that hangs is a check that reports nothing, so the expansion refuses a repeat
  and both jobs carry `timeout-minutes: 10`.
- **A `Chart.yaml` reclassifies the whole source** as Helm
  (`util/app/discovery/discovery.go`), with no `spec.source.helm` block anywhere
  in the `Application`. The directory read would have skipped `templates/`.

What is deliberately **out of scope**, and reported rather than flagged: an
`Application` sourcing a *different* repository. Its content is not in this git
history, so no diff and no render here can see what it applies — the script
names each such repository on stderr and walks on. The control for that is the
`AppProject` (`sourceRepos`), not CI, and today only `kairos-operator` has one.
A node operation arriving from a third-party repo is a reason to give
`kairos-upgrade` its own project, not a reason to teach this script to fetch.

**Both guards self-test before they are trusted.** No node operation manifest
exists in this repo, so both checks inspect zero documents and pass — which is
indistinguishable from a guard that has silently stopped detecting. So the job
first runs `nodeop_guard_selftest.sh` (25 pull requests replayed through a
throwaway git repository) and `nodeop_reachable_selftest.sh` (37 assertions over
rendered tree pairs, built with the same pinned kustomize CI uses). Each case
asserts the exit code the guard must return, and each script asserts its own
case count, so a case deleted rather than fixed fails the run instead of
quietly lowering the bar.

Confirmed by sabotage, measured rather than assumed — each number is how many
cases fail when that one behaviour is removed. Check one: disabling the
cardinality branch fails 7 cases, filtering changed paths down to names ending
`.yaml` fails 2, skipping the pre-image comparison fails 1. Check two: disabling
cardinality fails 9, refusing to follow self-referencing `Application`s fails 26,
dropping directory-type rendering fails 7, skipping the selector rule fails 2.
In the shared module, dropping `kind: List` expansion and dropping byte-order-mark
decoding each fail 1 case in *both* self-tests. A green `nodeop-guard` means "the
guards detect, and found nothing", not "nothing was looked at".

**The guards that enforce are the merge base's copies.** A pull request that
edits `nodeop_guard.py`, `nodeop_reachable.py` or their self-tests would
otherwise be graded by the very code it edits, with the self-test grading edited
fixtures — the check reports success and the unsafe manifest merges. The job
therefore checks the merge base out into a second worktree and runs the guards
from there; a pull request's own versions take effect on the pull request after
it. The proposed versions are self-tested too, unconditionally, in a separate
step, so that a change breaking its own guard fails immediately rather than a
merge later.

The set of scripts the merge base must carry is **fixed in the workflow**, not
derived from what the pull request contains. Deriving it is the obvious way to
write this and it is wrong: a pull request that merely *adds* a plausible helper
makes the merge base look incomplete, and a fallback keyed on that hands
enforcement straight back to the pull request's own copies. So: all five present
is the normal path; none present is the bootstrap of this very change, warned
about loudly and true only until it merges; anything in between is a hard error
rather than a fallback. (A pull request cannot dodge this by branching from an
ancient commit — on `pull_request`, `actions/checkout` gives a merge commit whose
merge base is always an ancestor of `main`.) The cost of the fixed list is that
**renaming or removing a guard script is a two-pull-request change**: rename and
list-edit in one commit leaves the merge base short of a name the workflow now
demands, which is the hard-error branch. Add the new name alongside the old,
then drop the old.

This raises the bar; it does not make the job tamper-proof, and the honest
statement of the limit is: GitHub runs the **workflow file itself**, and any local action it
calls, from the pull request head — so an edit to `nodeop-guard.yml`, or to
`.github/actions/kustomize/action.yml`, still decides what runs and what renders
it. Nothing inside the repository can close that. What closes it is repository
settings plus `.github/CODEOWNERS`, which this change adds — covering
`/.github/`, `/clusters/*/upgrades/` and `/base/kairos-operator/`. The owner is
spelled `@Vonor`: `@fam-melcher` is an organisation, and GitHub does not accept
an organisation as a code owner.

**Both jobs should be required status checks on `main`.** That is a repository
settings change (Settings → Branches → require status checks →
`kustomize-build`, `nodeop-guard` — the job names), it must be done by hand, and
nothing in this repo can do it or verify that it was done. Required status
checks, no force pushes and no deletions are the parts that work today.
"Require review from Code Owners" is not, with one maintainer: GitHub does not
accept a pull request's author as its approver, so enabling it would block every
merge. It becomes the control that closes the workflow-edit hole the day a
second maintainer exists, and `CODEOWNERS` is in place for that day.

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
- Both self-tests contain the literal strings `kind: NodeOp` and
  `kind: NodeOpUpgrade` in heredocs. These are test inputs for a linter, not
  manifests. They live under `.github/scripts/`, never under `clusters/`; they
  are referenced by no `kustomization.yaml` and reachable by no Application's
  `path`; and they exist as files only inside the `mktemp -d` directory each
  script's `trap` deletes. No cluster can render them and no node can be
  rebooted by them. The alternative is a guard whose correctness nobody can
  demonstrate.
- The guards run on pull requests only. A direct push to `main` bypasses them,
  which is why the branch protection above is not optional.
- A change to either guard takes effect on the *next* pull request, not on the
  one that makes it: the merge base's copies are what enforce. Expect the first
  encounter with this to read as "my fix did not run".
- `nodeop-guard` now renders every root in the Application closure, twice — at
  the merge base and at the head — so it needs the same pinned kustomize the
  `render` job uses. Both take it from `.github/actions/kustomize`, one version
  and one checksum for the repository.
- The closure check fails closed on shapes it does not model. Adding an
  `ApplicationSet`, or pointing an `Application` at this repository at a tag,
  fails `nodeop-guard` with exit 2 until the script is taught that shape. That
  is deliberate — a closure with a silent hole is worse than none — and it will
  look like an unrelated CI failure to whoever adds the first one.
- The one-node budget is **repository-wide, not per cluster**. A pull request
  upgrading one node on `k8s-dev` and one on `k8s-prod` is rejected. That is the
  intended reading — one node reboots at a time, whichever cluster it is in —
  but it is not what "one node per cluster" would mean, and the runbook's
  dev-before-prod rule already separates the two into different pull requests.
- The upgrade plan's `k8s-dev` "option A" — one manifest with no hostname
  selector, upgrading every node in a round under `concurrency: 1` — does not
  merge under this guard, on either cluster. That is deliberate: `concurrency`
  frees its slot when a reboot is *initiated*, not when the node returns, so the
  option it describes is the race the per-node shape exists to avoid. `k8s-dev`
  upgrades one node per pull request like `k8s-prod`, or this ADR gets an
  amendment that says why not.
- When `kairos-upgrade` lands, `kairos-operator`'s `AppProject` gains a second
  consumer, a second destination namespace (`kairos-system`), this repository as
  a second `sourceRepo`, and `NodeOpUpgrade` in its
  `namespaceResourceWhitelist`. The "exactly one consumer" argument for keeping
  it in `base/kairos-operator/` expires at that point; revisit the shared
  `base/projects/<name>/` alternative then rather than widening a project whose
  name would no longer describe it.
- `render` now depends on `nodeop_reachable.py --list-roots`, so a repository
  shape the closure refuses (an `ApplicationSet`, a self-reference pinned to a
  tag) fails `render` too, not only `nodeop-guard`. One definition of "what
  ArgoCD renders", used by both jobs, is worth that coupling.
- The guards bound how many **nodes** a pull request can disturb, not what
  happens on one. `NodeOp.spec.command` runs arbitrary commands in a privileged,
  HostPID container with the host filesystem mounted — one node's blast radius by
  count, and considerably more than one node's by consequence. `force: true` is
  bounded for a different reason: it only skips the version comparison, and
  adding it to a manifest already reachable changes that manifest, which spends
  the pull request's budget.
- An `Application` sourcing another repository is named on stderr in every run
  and walked no further. Expect those lines in the log — today they are ArgoCD,
  MetalLB, cert-manager, Envoy Gateway, Ceph and kairos-operator — and read them
  as "not covered here", not as a warning.

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
