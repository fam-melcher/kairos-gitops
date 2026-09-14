# Runbook — a node that will not come back

Kairos boots active → passive → recovery. An upgrade writes the new image to
active and flags the previous one passive; `upgradeRecovery` is left at its
default of false, so the recovery partition stays on the older version as a
second escape hatch.

## The node boots, but on the old version

Kairos' boot assessment fell back to the passive image on its own. Confirm, then
treat it as a failed round: abort ([node-upgrade-abort.md](node-upgrade-abort.md)),
investigate, retry under a new name.

```sh
ssh <node> 'grep KAIROS_VERSION /etc/kairos-release'
```

## The node does not boot at all

Attach a console. At the GRUB menu choose the **passive** entry (the previous
image) or, failing that, **recovery**. Once it is up, it is the case above.

## The node is up but stays cordoned

Expected after a failure — `uncordonOnFailure` is false so the node can be
inspected. Release it by hand once it is healthy:

```sh
kubectl uncordon <node>
```

## etcd lost quorum

Stop here and restore from the snapshot taken before the round
([etcd-snapshot.md](etcd-snapshot.md)) following k3s' documented restore
procedure. Do not start another upgrade round until every member reports healthy.
