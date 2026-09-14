# Runbook — aborting an upgrade round

Use when a round must stop before the next node starts.

1. Delete the custom resource. `selfHeal: false` on `kairos-upgrade` is what
   makes this hold at all:

   ```sh
   kubectl -n kairos-system delete nodeopupgrade <name>
   ```

2. `kairos-upgrade` now shows `OutOfSync`. That is expected.

3. **Uncordon by hand.** Deletion does not uncordon: the controller's deletion
   path only removes its ClusterRoleBinding.

   ```sh
   kubectl get nodes            # look for SchedulingDisabled
   kubectl uncordon <node>
   ```

4. **Land a pull request removing the manifest, promptly.** The delete holds only
   until the next commit reaches `main`: `targetRevision: HEAD` means any commit
   changes the target revision, which clears ArgoCD's "already attempted" guard
   and re-syncs the object back. Recreated, it is a new object to the controller
   and the upgrade runs again — on a node that may be cordoned and half-upgraded.

5. The manifest's name is now burned. Any retry uses a new, never-used name, and
   starts again from the top of [node-upgrade.md](node-upgrade.md).
