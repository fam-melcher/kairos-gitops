# 0016 — A self-guarding, cluster-wide `NodeOp` via `spec.preflight`

- Status: Accepted
- Date: 2026-09-26

## Context

ADR 0015 added a `node-config` `AppProject` scoped to bare `NodeOp` objects,
built around the same per-hostname, one-PR-per-node shape `NodeOpUpgrade`
uses. That shape has a real cost this ADR exists to remove: a `NodeOp` bound
to a specific `kubernetes.io/hostname` does not survive that node being
replaced. This cluster's actual node-lifecycle model is explicitly
cattle-not-pets — a dead node is replaced by reprovisioning from a profile in
`kairos-configs` (a repository this one has no visibility into), not by
repairing the same named node. A hostname-bound `NodeOp` silently stops
applying to a cluster the moment the node it named is gone, and the
replacement comes up without the k3s OIDC flags until a human notices and
writes a new one-off manifest for the new name. That is exactly backwards
for how this cluster is actually operated.

## Problem

`nodeop-guard`'s bounded-blast-radius rule (ADR 0013) rejected a cluster-wide
`NodeOp` outright: *"a `NodeOp` runs an arbitrary command and has no version
comparison to skip nodes that need nothing, so 'every node, one at a time' is
every node, without exception."* That reasoning is correct for a bare
command with no self-check — but it assumed no such self-check exists for
`NodeOp`. It does: `spec.preflight`.

## Investigation

Read `kairos-operator`'s actual controller source
(`internal/controller/nodeop_controller.go` at `v0.2.2`), not just its docs,
to answer two questions before trusting a design on them:

1. **Does `spec.preflight` genuinely let a `NodeOp` skip a node that's
   already done, the way `NodeOpUpgrade`'s version check does?** Yes,
   verified in `advancePreflight`/`manageJobCreation`: a preflight Pod runs
   per node before cordon/drain/the main Job; a non-empty termination log
   ends that node at `Phase=Completed` with no Job ever created — "no
   cordon, no drain, no main Job" (upstream's own docs, corroborated by the
   controller code path).
2. **Does the controller ever notice a node that joins *after* the `NodeOp`
   was created and already reconciled to completion for every node that
   existed at the time?** Yes, and this is the load-bearing fact for
   "node-agnostic without a repo change": `Reconcile` unconditionally
   returns `ctrl.Result{RequeueAfter: time.Minute * 5}` regardless of phase —
   there is no short-circuit for a "done" `NodeOp`. Every five minutes,
   `manageJobCreation` calls `getTargetNodes`, which re-lists the cluster's
   *current* live nodes and re-evaluates the selector fresh — it does not
   consult a cached membership snapshot from creation time. A node is only
   ever excluded from a future round once it has an entry in
   `status.nodeStatuses`; a brand-new node has no such entry and is
   therefore in `manageJobCreation`'s `freshNodes` set on the very next
   reconcile after it joins. The controller does **not** additionally watch
   `Node` objects directly (`SetupWithManager` only watches its own `NodeOp`,
   child `Job`s and reboot/preflight `Pod`s) — the mechanism is the
   unconditional five-minute requeue plus a fresh list on every reconcile,
   not an event-driven watch. Either way, the observable result is the same:
   a newly-joined matching node is reached within about five minutes, with
   no git change.

This means a **single, persistent, cluster-wide `NodeOp`** with a preflight
that checks "does this node already have the file" gives exactly the
property this cluster's operators actually want: replace a node, it joins
with the same selector-matching label, the existing `NodeOp` notices within
five minutes, runs the check, finds the file missing, and configures it —
once, automatically, no PR.

## Decision

### The guard changes, not the design

Per direct instruction: the design does not route around `nodeop-guard`, the
guard is amended to recognise the safe shape it was missing. `nodeop_common
.check_bounded` gains a third mode, alongside the existing per-hostname mode
and `NodeOpUpgrade`'s version-check mode: **a `NodeOp` with `spec.preflight`
set**, under the same `concurrency: 1` / `stopOnFailure: true` discipline as
the `NodeOpUpgrade` case, and the same `matchExpressions` prohibition. This
is exactly the "no version comparison to skip nodes" gap the original rule
named — closed, not ignored, because `spec.preflight` is a strictly more
general per-node skip than a version string. Both guard self-tests gained
cases proving the new mode is accepted correctly and that it still rejects
the shapes that remain unsafe (no `stopOnFailure`, `concurrency` above 1) —
verified locally, all passing, before this ADR was written down as done
rather than proposed.

### The manifest

One `NodeOp`, created once, never one-per-node and never deleted:

```yaml
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOp
metadata:
  name: k3s-oidc-config
  namespace: kairos-system
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: "true"
  image: quay.io/kairos/hadron
  preflight:
    command:
      - sh
      - -c
      - |
        if [ -f /host/oem/90-k3s-oidc.yaml ]; then
          echo "90-k3s-oidc.yaml already present" > /dev/termination-log
        fi
        exit 0
  command:
    - sh
    - -c
    - |
      set -e
      cat > /host/oem/90-k3s-oidc.yaml << 'EOF'
      #cloud-config
      stages:
        initramfs:
          - name: "write k3s OIDC drop-in"
            commands:
              - mkdir -p /etc/rancher/k3s/config.yaml.d
            files:
              - path: /etc/rancher/k3s/config.yaml.d/90-oidc.yaml
                permissions: 0600
                owner: 0
                group: 0
                content: |
                  kube-apiserver-arg:
                    - oidc-issuer-url=https://keycloak.k8s-prod.home.fam-melcher.net/realms/fam-melcher
                    - oidc-client-id=kubectl
                    - oidc-username-claim=preferred_username
                    - oidc-groups-claim=groups
      EOF
      sync
  hostMountPath: /host
  cordon: true
  drainOptions:
    enabled: true
  rebootOnSuccess: true
  concurrency: 1
  stopOnFailure: true
```

`nodeSelector.matchLabels` names `node-role.kubernetes.io/control-plane`, not
a hostname — every current and future `k8s-prod` server node carries this
label by construction (it is how k3s itself marks a server node), and
`k8s-prod` has no workers to accidentally include. The preflight checks for
the *durable* `/oem` source file, not the ephemeral `/etc` path materialised
from it at boot — the file that persists is the one worth checking, and
checking it is exactly "has this already run on this node."

`concurrency: 1` + `stopOnFailure: true` bound this exactly the way
`NodeOpUpgrade` bounds a cluster-wide round: only one node is ever mid-reboot
at a time, and a failure halts the round rather than cascading into a second
control-plane member while the first is still down.

### `node-config`'s Application syncs this one file, forever

Unlike ADR 0015's original one-PR-per-node plan, `clusters/k8s-prod/
node-ops/` now holds exactly one file for the life of this design. `selfHeal:
true` (already the case from ADR 0015) keeps it in place; there is no round
to end and no manifest to remove the way `NodeOpUpgrade`'s one-shot rounds
work (ADR 0014) — this object's job is to keep existing indefinitely and
keep noticing new nodes.

## Consequences

- A node replacement never touches this repository. The new node joins with
  the same `node-role.kubernetes.io/control-plane` label, the existing
  `NodeOp` reaches it within about five minutes, and it is configured and
  rebooted once — matching the actual operational model instead of fighting
  it.
- The guard's new mode 3 is available to any future `NodeOp` that can
  express its own idempotency as a preflight check, not only this one —
  intentionally, since the underlying safety argument (a genuine per-node
  skip) is general, not specific to OIDC config.
- `status.nodeStatuses` grows one entry per node this `NodeOp` has ever seen
  and never shrinks on its own — harmless (a small map, no upper bound
  concern at three-to-a-handful of nodes) but worth knowing before assuming
  the object's status is a live "current membership" view; it is a
  cumulative history of every node ever matched.
- If the OIDC flags themselves ever need to change (a realm rename, say — as
  already happened once this session), the fix is **not** editing this
  `NodeOp`'s command and expecting it to re-run: `status.nodeStatuses`
  already marks every existing node `Completed`, so `manageJobCreation`'s
  fresh-node pass would not touch them again on a spec-only edit (per
  upstream's own one-shot-semantics warning, echoed in ADR 0015). A real
  config change needs a new object (new name, e.g.
  `k3s-oidc-config-v2`) — the same "new name for a new round" discipline
  ADR 0014 established for `NodeOpUpgrade`, now applying here too.

## Rationale

ADR 0013 built `nodeop-guard` to encode a safety argument, not a specific
list of allowed kinds — and the argument was always "does this shape have a
way to skip a node that needs nothing." `NodeOpUpgrade` had one built in;
bare `NodeOp` didn't seem to, until `spec.preflight` was checked against the
actual controller rather than assumed absent. Amending the guard to match
that finding is exactly the process ADR 0013 designed for: the guard is
supposed to be current with what the operator can actually prove safe, not a
fixed list frozen at the day it was written.
</content>
