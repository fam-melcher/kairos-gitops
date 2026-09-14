# Runbook — upgrading Kairos on a cluster

One `NodeOpUpgrade` upgrades the whole cluster, one node at a time. The design
and the evidence for that are in [ADR 0014](../adr/0014-kairos-upgrades-one-reviewed-nodeopupgrade.md);
this is the procedure.

**Do not land any change under `clusters/<cluster>/upgrades/` while a round is
running.** `prune: true` deletes the in-flight object, which cascade-deletes its
`NodeOp` and Jobs, and the controller does not uncordon on deletion — the node
stays cordoned with nothing left to release it.

## 1. Before the pull request

```sh
kubectl get nodes -o wide                       # all Ready, none SchedulingDisabled
kubectl -n kube-system get pods                 # nothing pending or crashlooping
sudo k3s etcdctl endpoint status --cluster -w table   # every member healthy
```

Take an etcd snapshot and copy it off the node — see
[etcd-snapshot.md](etcd-snapshot.md).

Pre-pull the target image on **every** node. The preflight Pod has a hard-coded
120 second deadline that covers pulling *and* unpacking the image; a node that
misses it is marked Failed, `stopOnFailure` halts the round, and the manifest's
name is burned (a retry needs a new name).

```sh
sudo k3s crictl pull <target image>
```

Note the version the nodes run now, for the comparison afterwards:

```sh
grep KAIROS_VERSION /etc/kairos-release
```

## 2. The pull request

Add one file under `clusters/<cluster>/upgrades/` and list it in that
directory's `kustomization.yaml`. The target version goes in the file name and
in `metadata.name` — a reused name is a spec update, whose behaviour upstream
declares undefined.

```yaml
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  name: hadron-prod-v0-4-1
  namespace: kairos-system
spec:
  image: quay.io/kairos/hadron:v0.4.1-standard-amd64-generic-<kairos>-k3s-<k3s>-k3s1
  nodeSelector:
    matchLabels:
      kairos.io/managed: "true"
  concurrency: 1
  stopOnFailure: true
```

Pair it with a `kairos-configs` pull request bumping `scripts/build-iso.sh`, so a
node reinstalled from an ISO does not come back older than the cluster. Neither
merges without the other.

CI rejects the manifest if it does not bound itself: no selector, two node
operations in one pull request, `matchExpressions`, `concurrency` other than 1
without a hostname, a missing `stopOnFailure`, or `force: true` on a
cluster-wide round.

## 3. While it runs

```sh
kubectl -n kairos-system get nodeopupgrade,nodeop -w
kubectl get nodes -w
kubectl -n kairos-system get nodeop <name> -o jsonpath='{.status.nodeStatuses}' | jq
```

Expected per node: `Preflight` → `Running` → `Completed` with
`rebootStatus: pending` → node goes NotReady → node returns Ready →
`rebootStatus: completed`, and only then does the next node start. A node
already at the target version is skipped by preflight without a reboot.

If a node fails, the round stops there by `stopOnFailure`. The failed node stays
cordoned on purpose — see [node-upgrade-abort.md](node-upgrade-abort.md) and
[node-upgrade-rollback.md](node-upgrade-rollback.md).

## 4. After

```sh
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
ssh <node> 'grep KAIROS_VERSION /etc/kairos-release; k3s --version'
sudo k3s etcdctl endpoint status --cluster -w table
```

Then close the round with a pull request removing the manifest and its
`kustomization.yaml` entry. `prune` deletes the completed object; git keeps the
record.
