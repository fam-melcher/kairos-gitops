# 0014 — Kairos OS upgrades as one reviewed `NodeOpUpgrade` per cluster

- Status: Accepted
- Date: 2026-09-14

## Context

ADR 0012 installed `kairos-operator`; ADR 0013 gave it a project and the CI that
bounds what a node operation may do. Neither creates a custom resource, so
nothing in this repo can upgrade a node yet. This ADR adds that path.

The operator exists for exactly this: a `NodeOpUpgrade` names an OS image, and
the controller runs a preflight check, cordons, drains, upgrades and reboots each
selected node. What this repo has to decide is the shape of the object in git,
who may create it, and what happens between rounds.

`kairos-configs` builds the ISO; `/usr/bin/k3s` on a running node confirms k3s
comes from the immutable image rather than from persisted `/usr/local`, so an
image bump moves both the OS and k3s together.

## Problem

An upgrade is a one-shot event; git is a description of steady state. How does a
reviewed commit start exactly one upgrade round, and how does the cluster's blast
radius stay bounded while it runs?

## Considered Alternatives

1. **One manifest per node, one pull request per node** (an earlier plan in this
   repo). The claim was that `concurrency: 1` sequences by wall-clock luck
   because the operator frees its slot when a reboot is *initiated*, so only the
   absence of node two's manifest would stop node two from draining while node
   one is down. **Checked against `v0.2.2` and false.** `countRunningJobs`
   (`internal/controller/nodeop_controller.go:1506`) counts a node as in flight
   while `Phase=Completed && RebootStatus=pending`, and only
   `isRebootPodCompleted` clears that: the reboot Pod is `restartPolicy:
   OnFailure` with infinite `NoExecute` tolerations — deliberately, so it
   "survives the NotReady/Unreachable window caused by the very reboot it
   triggers" — and after the node boots it re-runs, finds its own
   `kairos.io/reboot-state: completed` annotation, and exits 0. The slot is held
   until the node is back. Rejected: three pull requests and three verification
   gates buy nothing the controller does not already do, while tripling the
   chance of a round left half-finished.
2. **`metadata.generateName` with `kubectl create`**, upstream's one-off
   workflow. Correct semantics, but the run does not live in git and its name is
   unknown ahead of time. Rejected on both counts, which is also upstream's own
   framing of the tradeoff.
3. **One long-lived `NodeOpUpgrade` whose `image` is bumped.** Rejected on
   upstream's explicit warning: a `NodeOpUpgrade` is a single run, the API allows
   a `spec` update but behaviour after one is undefined.
4. **A static name carrying the target version, bumped with the image.** Chosen.
   It is upstream's documented GitOps equivalent of `generateName`: each merged
   commit names a new object, which the operator treats as a new one-shot run.

## Decision

### The shape of a round

One `NodeOpUpgrade` per cluster per round, in
`clusters/<cluster>/upgrades/`, listed in that directory's `kustomization.yaml`,
with the target version in **both** the file name and `metadata.name`:

```yaml
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  # The version fragment is load-bearing. The same name across two commits is a
  # spec update, whose behaviour upstream declares undefined.
  name: hadron-prod-v0-4-1
  namespace: kairos-system
spec:
  image: quay.io/kairos/hadron:v0.4.1-standard-amd64-generic-v4.1.2-k3s-v1.36.1-k3s1
  nodeSelector:
    matchLabels:
      kairos.io/managed: "true"
  concurrency: 1
  stopOnFailure: true
```

Four fields, one object, the whole cluster — upstream's canary example, and the
sequencing evidence in alternative 1 is why it is enough. `stopOnFailure: true`
is the other half: a node that does not come back halts the round instead of
handing its slot to the next one.

The round ends with a pull request that removes the manifest from
`kustomization.yaml`. `prune: true` then deletes the completed object. Git is the
archive — there is no `archive/` directory, because the name already carries the
version and the history already has the manifest.

### `kairos-upgrade`, and its own project

A second Application, `kairos-upgrade`, syncs `clusters/<cluster>/upgrades` —
the same per-cluster-path shape `metallb-config` and `gateway` use (ADR 0007).
It runs under its own `AppProject`, not `kairos-operator`'s: that project allows
the *upstream* repo into `operator-system`, this one allows *this* repo into
`kairos-system`, and a shared project would have to be the union, which is wider
than either app needs. ADR 0013 said to revisit its "exactly one consumer"
argument when this app landed; this is that revisit, and the answer is a second
narrow project rather than one wide one.

The whitelist is two kinds: `Namespace`, and `NodeOpUpgrade`. `NodeOp` — the
run-any-command kind — is deliberately absent. Adding it is an amendment to this
ADR, not something a commit under `upgrades/` can reach.

`selfHeal: false` is deliberate and is the one place in this repo where drift is
a feature: the documented abort is `kubectl delete nodeopupgrade`, and with
selfHeal ArgoCD recreates the object within seconds — as a *new* object, because
its child `NodeOp` was cascade-deleted with it, so the upgrade re-runs on a node
that is cordoned and possibly half-broken. The honest limit, which the abort
runbook states: `targetRevision: HEAD` means any commit landing on `main`
changes the target revision and re-syncs, so the delete holds only until the next
merge. The abort ends with a pull request, not with the delete.

Ordering follows ADR 0008 — `retry` plus `SkipDryRunOnMissingResource=true`, no
sync waves, because `Application` has no health assessment and a wave would
document an intent the mechanism does not deliver.

### What CI enforces

ADR 0013's guards keep their cardinality rule — at most one node operation
introduced, or made reachable, per pull request. The selector rule changes:
"exactly one `kubernetes.io/hostname`" would have rejected the manifest above,
which is the shape upstream documents and this ADR adopts. A node operation is
now bounded if **either**

1. it names one node with `kubernetes.io/hostname` (further `matchLabels` may
   narrow it; `matchExpressions` is rejected on presence, since an `In` list over
   three nodes reads like a selector and upgrades three nodes), **or**
2. it is a `NodeOpUpgrade` with `concurrency: 1` and `stopOnFailure: true`.

Mode 2 is `NodeOpUpgrade`-only. A `NodeOp` runs an arbitrary command with no
version comparison, so "every node, one at a time" is every node without
exception; that one names a host. Mode 2 also refuses `force: true`, which
returns `nil` from `buildUpgradePreflight` (`nodeopupgrade_controller.go:162`) —
no preflight at all, so a round that would have skipped up-to-date nodes reboots
every one of them.

## Consequences

- **Rounds are indivisible.** Do not land any change to `upgrades/` while a round
  is running: `prune` deletes the in-flight `NodeOpUpgrade`, which
  cascade-deletes its `NodeOp` and Jobs, and `handleDeletion` does not uncordon —
  the node stays cordoned with nothing left to release it.
- **The preflight deadline is 120 seconds and not configurable from this CRD**
  (`buildUpgradePreflight` hard-codes it). That budget covers pulling *and*
  unpacking the upgrade image on the node. Pre-pull the target image on every
  node before merging, or a slow node fails preflight, `stopOnFailure` halts the
  round, and the object's name is burned — the controller creates its child
  `NodeOp` once per name, so a retry is a new, differently-named manifest.
- **There is no dev cluster to rehearse on.** `clusters/k8s-dev/` exists and
  renders, but no cluster runs it, so the first real exercise of cordon, drain,
  upgrade, sentinel and reboot is `k8s-prod`. The etcd snapshot in the runbook is
  not optional for that reason.
- **The image tag is paired with `kairos-configs` by hand.** The upgrade image
  lives here; the install image lives in `kairos-configs/scripts/build-iso.sh`.
  Nothing keeps them in sync, so a node reinstalled from an old ISO comes back
  older than the cluster. Any pull request landing a new tag here is paired with a
  `build-iso.sh` bump there, and the ISOs rebuilt.
- **A version bump is two edits in one commit** — `spec.image` and the version
  fragment of `metadata.name`. Upstream documents a Renovate configuration that
  writes both; this repo does not run Renovate yet, so the pairing is the
  reviewer's job, and a bump that moves only the image produces no new object and
  no upgrade.
- **`kairos-system` is `pod-security: privileged`.** The operator runs the
  upgrade Job, the preflight Pod and the reboot Pod there with HostPID and the
  host filesystem mounted. k3s enforces no PSA baseline today; the labels are
  there so that enabling one later does not break upgrades silently.

## Rationale

The earlier design in this repo treated the operator as a mechanism that could
not be trusted to sequence, and rebuilt sequencing out of pull requests. Reading
the controller showed the opposite: the reboot Pod's `OnFailure` restart policy
and its infinite `NoExecute` tolerations exist precisely so that a node's
concurrency slot is held across its own reboot, and upstream's documentation
leads with the four-field canary manifest for that reason.

What remains genuinely this repository's problem is everything around the round:
which object exists, who reviewed it, that exactly one can appear per merge, that
a finished round is removed, and that an abort is not undone by auto-sync. That
is what this ADR fixes, and it is a smaller thing than the mechanism it replaces.
