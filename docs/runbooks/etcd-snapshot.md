# Runbook — etcd snapshot before an upgrade

An upgrade round reboots every control-plane node in turn. Take a snapshot first
and get it off the node, because a snapshot stored only on the node that fails is
not a backup.

```sh
# on any server node
sudo k3s etcd-snapshot save --name pre-upgrade-$(date +%F)
sudo k3s etcd-snapshot ls
```

Snapshots land in `/var/lib/rancher/k3s/server/db/snapshots/`. Copy the newest
one somewhere off the cluster:

```sh
scp <node>:/var/lib/rancher/k3s/server/db/snapshots/pre-upgrade-<date>* ./
```

Verify the copy is non-empty before starting the round. Restoring is k3s'
`server --cluster-reset --cluster-reset-restore-path=<snapshot>` procedure; read
k3s' current documentation at the time you need it rather than trusting a copy
here.
