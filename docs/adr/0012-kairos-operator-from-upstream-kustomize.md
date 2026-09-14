# 0012 — kairos-operator from upstream's `config/default`, pinned to `v0.2.2`

- Status: Accepted
- Date: 2026-09-10

## Context

Both clusters run Kairos, provisioned by `kairos-configs`. Nothing in either
cluster can currently drive a node-level operation — a cordon, a drain, an OS
image swap — from the cluster itself. `kairos-operator`
(`github.com/kairos-io/kairos-operator`) is the project's own controller for
that: it owns the `NodeOp`, `NodeOpUpgrade` and `OSArtifact` CRDs.

This ADR covers installing the operator only. No `NodeOp` or `NodeOpUpgrade`
resource is created by this change, on either cluster.

## Problem

Which upstream artifact does this repo deploy, at which version, into which
namespace, with which sync options, on which clusters?

## Considered Alternatives

1. **The bundled Helm chart.** Since `v0.2.0` the repository ships
   `charts/kairos-operator/`. ADR 0010 established that a chart is not barred —
   the question is which artifact the project actually publishes. Checked, not
   assumed: at tag `v0.2.2` the in-tree `Chart.yaml` is `version: 0.2.1` /
   `appVersion: v0.2.1`, while the release attachment
   `kairos-operator-0.2.2.tgz` is `0.2.2` / `v0.2.2`. There is no Helm
   repository behind either — `kairos-io.github.io/kairos-operator/index.yaml`
   and `kairos-io.github.io/helm-charts/index.yaml` both 404, and
   `helm show chart oci://quay.io/kairos/kairos-operator --version 0.2.2`
   returns `401 unauthorized`. The only coherent chart artifact is a GitHub
   release attachment, which ArgoCD cannot source. Rejected on availability.
2. **The release attachment `install.yaml`.** Same reason.
3. **`path: config/default` at a pinned tag.** Chosen — the shape `base/argocd`
   and `base/metallb` already use.

## Decision

`base/kairos-operator/application.yaml` sources
`github.com/kairos-io/kairos-operator`, `path: config/default`. Per this repo's
universal convention the base omits `spec.source.targetRevision`; each cluster's
`version-patch.yaml` supplies `v0.2.2`. Both clusters get the app.

### The tag does not pin the image, and that is upstream's shape, not a mistake here

`config/default` at **every** `kairos-operator` tag pins the **previous**
release's images, because the version-bump commit lands on `main` after the tag
is cut. Measured with `git show <tag>:config/default/kustomization.yaml`:

| tag | rendered image |
|---|---|
| `v0.1.1` | `v0.1.0` |
| `v0.1.2` | `v0.1.1` |
| `v0.1.3` | `v0.1.2` |
| `v0.2.0` | `v0.1.3` |
| `v0.2.1` | `v0.1.3` |
| `v0.2.2` | `v0.2.1` |
| `main` | `v0.2.2` |

Corroborated from the other side: `kustomize build config/default` at `main`'s
`ca0164d` is byte-identical (364,879 bytes) to the `install.yaml` attached to
the `v0.2.2` release. Upstream's own deployment artifact corresponds to a
post-tag commit.

So `targetRevision: v0.2.2` deploys `v0.2.2` manifests running `v0.2.1` images.
Pinning an older tag is worse (`v0.2.1` renders `v0.1.3`). Overriding the images
from the overlay was rejected on measurement. `config/default` carries four
inline JSON6902 patches on the Deployment: an `image` replace, and three env
additions — `NODE_LABELER_IMAGE` (`v0.2.1`), `SENTINEL_IMAGE` (empty string) and
`NODEOP_DEFAULT_IMAGE` (`busybox:latest`). Simulating exactly what ArgoCD does —
`kustomize edit set image` inside `config/default`, then build — updates the
container `image` and, through upstream's own `replacements:` block, the
`OPERATOR_IMAGE` env var. It reaches none of the three env literals, because a
kustomize image transformer matches image *fields* and those are string values.
So an image override leaves `NODE_LABELER_IMAGE` stale, and leaves two further
image references untouched that were never pinned at all: `SENTINEL_IMAGE`,
which upstream's own chart documents as falling back to `NodeOp.spec.image` and
then `busybox:latest`, and `NODEOP_DEFAULT_IMAGE`, already at the mutable
`busybox:latest`. A coherent override needs at least two of this repo's own
overrides layered on someone else's patch list, and still does not make the
result self-consistent. That is what ADR 0004 and ADR 0010 exist to avoid.

The lag is inert for what this change does, and that is why it is accepted
rather than merely tolerated: `operator.kairos.io_nodeops.yaml` and
`..._nodeopupgrades.yaml` are byte-identical between `v0.2.1` and `v0.2.2`; the
only CRD that changed is `osartifacts.build.kairos.io`; and
`git diff --numstat v0.2.1 v0.2.2 -- 'internal/controller/*.go' ':(exclude)internal/controller/*_test.go'`
lists exactly two files, as `<insertions> <deletions> <path>`: `job.go` 55/20
(OSArtifact build-command fixes) and `nodeop_controller.go` 22/0 (the reboot
pod's `NoExecute` tolerations). `--numstat` rather than `--stat` on purpose —
`--stat`'s single column is insertions *plus* deletions, which reads as 75 for
`job.go`.
Nothing in this change creates a CR of any of the three kinds.

### Namespace: `operator-system`, and upstream creates it

`config/default` sets `namespace: operator-system` with `namePrefix: operator-`,
and `config/manager/manager.yaml` ships a `Namespace` named `system` that the
prefix renames. The rendered tree therefore contains `Namespace/operator-system`
(204 bytes, no `pod-security.*` labels).

- **`CreateNamespace=true` is not set.** Upstream owns the object; a second
  owner is ADR 0004's failure mode, the same call `base/metallb` makes.
- **`managedNamespaceMetadata` is not used, and could not be.** ArgoCD v3.4.5's
  sync-options documentation requires `CreateNamespace=true` for it to do
  anything at all, and states that a Namespace manifest inside the Application
  overwrites whatever it sets. Both apply. This is the exact inverse of
  `base/ceph-csi-rbd`, whose chart ships no Namespace and which therefore both
  creates it and labels it.
- **Renaming it was rejected on measurement.** `operator-system` is a
  kubebuilder scaffold default that names no operator, and ArgoCD's
  `source.kustomize.namespace` can rename it — including the `Namespace` object
  itself. But simulating the rename leaves
  `ClusterRoleBinding/operator-metrics-auth-rolebinding` pointing its subject at
  `namespace: operator-system`, because `config/rbac/metrics_auth_role_binding.yaml`
  hardcodes both the already-prefixed subject name and the namespace, so
  kustomize's name-reference resolution cannot match it. The rename would
  silently break the metrics authn/authz binding.
- **PodSecurity labelling is therefore unavailable, and would eventually be
  needed.** The operator's own Deployment is `restricted`-compliant
  (`runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: [ALL]`,
  `seccompProfile: RuntimeDefault`). Its runtime children are not: at controller
  startup it creates a `node-labeler` DaemonSet in its own namespace mounting
  `hostPath: /etc`, which violates `baseline`. No PodSecurity enforcement exists
  on these clusters, so this is latent. If enforcement is ever turned on, this
  app needs a decision, not a tweak — and the cheapest option to weigh first is
  a one-time, out-of-band `kubectl label namespace operator-system
  pod-security.kubernetes.io/enforce=privileged`, which labels the namespace
  without git taking ownership of it. Same posture this repo already accepts for
  the Ceph and Cloudflare Secrets, and for branch protection.

### Sync options: one present, three absent

`ServerSideApply=true` is required, and upstream says so directly. Its
installation documentation (https://kairos.io/operator-docs/installation/):
*"`ServerSideApply=true` is required. The operator's CRDs (in particular
`OSArtifact`) exceed the 262 kB `last-applied-configuration` annotation limit
and fail with `metadata.annotations: Too long` under client-side apply."*

Corroborated locally per ADR 0003's rule — and the corroboration is the weaker
of the two, which is why it comes second. Measuring the rendered `v0.2.2` tree
the way ADR 0011 measured cert-manager's, as the UTF-8 length of each object's
fragment from `kustomize build` split on the `---` separator with the trailing
newline stripped: `osartifacts.build.kairos.io` is **338,756 bytes**, against
8,850 and 7,654 for the other two CRDs and 2,755 for the Deployment. But the
annotation client-side apply writes is JSON, not YAML, and the same object as
compact JSON is 112,635 bytes — *under* the limit. Raw YAML bytes is the
convention this repo already uses, and it puts this CRD in the same size class
that triggered the option for cert-manager and Envoy Gateway, but it is not by
itself proof. Upstream's statement is.

- `CreateNamespace=true` — see above.
- `PrunePropagationPolicy=foreground` — ArgoCD v3.4.5 documents foreground as
  the default for pruning. Setting it changes nothing.
- `PruneLast=true` — nothing this app syncs has a prune-order dependency on
  anything else it syncs. It is sometimes reached for as mitigation for an
  upstream release dropping a CRD from `config/default`, which ArgoCD would
  prune and thereby cascade-delete every CR of it; it does not prevent that
  prune, only reorders it. Adopting a knob for a purpose it does not serve is
  ADR 0008's named failure mode. The real mitigation is below, in consequences.
- `SkipDryRunOnMissingResource=true` and a `retry:` block — both exist on
  `metallb-config`, `gateway` and `cert-manager-config` for one reason (ADR
  0008): those apps sync CRs whose CRDs a *different* Application installs, and
  nothing can order two Applications. This app is self-contained — CRDs and
  everything using them in one sync, where ArgoCD orders CRDs first and skips
  the dry run for a CR whose CRD is in the same sync — and in any case syncs no
  CRs at all. There is also no admission webhook in the rendered tree to be
  rejected by. Setting either would document an ordering intent this app does
  not have.

`ignoreDifferences` is absent. ADR 0006's bar is that a pre-emptive entry
requires structurally certain drift. The rendered tree contains zero webhook
configurations, so the `caBundle` drift `base/metallb` and `base/cert-manager`
both carry entries for cannot occur; CRD `status` is already excluded by
ArgoCD's default `ignoreResourceStatusField: all`; and the objects the operator
creates at runtime are never part of the desired state.

### Both clusters

`base/ceph-csi-rbd` is prod-only, and the precedent does not transfer: ADR
0010's reason is an undecided external dependency — whether `k8s-dev` uses Ceph
at all. `kairos-operator` has no external dependency; it needs Kairos nodes,
which `k8s-dev` has by construction. And ADR 0008's rule that the repo must be
correct by construction on every rebuild applies to `k8s-dev` whether or not one
is running today. There is no running `k8s-dev` cluster, so enabling it costs
nothing at runtime and buys a rendered overlay that CI keeps honest.

## Consequences

- The operator installs 19 objects: 1 Namespace, 3 CRDs, 8 ClusterRoles, 2
  ClusterRoleBindings, 1 ServiceAccount, 1 Role, 1 RoleBinding, 1 Service, 1
  Deployment. **Fourteen** of those are cluster-scoped — the Namespace, the
  three CRDs, the eight ClusterRoles and the two ClusterRoleBindings. The
  remaining five are namespaced.
- **`kubectl -n operator-system get deploy operator-kairos-operator -o jsonpath='{.spec.template.spec.containers[0].image}'`
  returns `quay.io/kairos/operator:v0.2.1` while this repo pins `v0.2.2`.** That
  is the documented lag, not drift. The same command over
  `{.spec.template.spec.containers[0].env[*]}` shows `OPERATOR_IMAGE` and
  `NODE_LABELER_IMAGE` at the same version.
- **Never bump `targetRevision` casually.** This app runs `prune: true`. An
  upstream restructure that drops a CRD from `config/default`'s output would
  have ArgoCD prune it, and a pruned CRD cascade-deletes every CR of it. The
  mitigation is a human reading `git diff <old>..<new> -- config/` before
  changing the pin, and it is a review obligation, not a setting.
- The operator creates objects ArgoCD does not track: a `node-labeler`
  DaemonSet, one Job per node, and a `kairos-node-labeler` ServiceAccount with
  its own Role, RoleBinding, ClusterRole and ClusterRoleBinding. They appear in
  the namespace but not in the Application's resource tree, and `prune` will
  never touch them.
- The node-labeler DaemonSet carries `nodeSelector: kairos.io/managed=true`, a
  label the operator's own per-node Jobs apply. On a cluster whose nodes are not
  Kairos, it would schedule nowhere and sit at zero replicas.
- **No node operation runs.** Installing the operator creates no `NodeOp` and no
  `NodeOpUpgrade`, and the controller cordons, drains and reboots nothing
  without one. It is not a no-op, though — the node-labeler DaemonSet and its
  per-node Jobs start on first reconcile, as the bullets above record.

### Supply chain, accepted explicitly

`targetRevision: v0.2.2` is a **mutable git tag**, not a commit SHA; the image it
renders, `quay.io/kairos/operator:v0.2.1`, is a **mutable image tag**, not a
digest; and upstream builds with `provenance: false, sbom: false` and ships no
cosign signature. Every other app in this repo pins a tag or a chart version the
same way, so this is consistent — but this is by a distance the most privileged
app in the repo, and inheriting the convention silently is the wrong way to
arrive at it. It is accepted deliberately, on the same footing as ADR 0010's and
ADR 0011's out-of-band Secrets: proportionate at this scale, and the first thing
to revisit if this repo ever adopts digest pinning or signature verification.

## Rationale

The interesting decision here is not which directory to point at — this repo
settled that at ADR 0004. It is what to do when upstream's tag and upstream's
published artifact disagree, which they do at every tag of this project. The
choice is between deploying what a tag actually renders and reconstructing what
upstream meant, and the second one only looks cheap until you measure it: the
image transformer reaches one of the two image references and silently misses
the other. Deploying the tag verbatim and writing down what it deploys keeps the
repo honest about a lag that would otherwise be discovered by someone reading
`kubectl get deploy` and mistrusting the version pin.
