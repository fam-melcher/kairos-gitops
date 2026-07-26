# kairos-gitops

GitOps workload repo for the k3s clusters provisioned by
[kairos-configs](https://github.com/fam-melcher/kairos-configs). Each
cluster's genesis node bootstraps a bare ArgoCD instance and stages one
root `Application` pointed at `clusters/<cluster-name>` in this repo
(`gitops-repo`/`gitops-path` values, kairos-configs' ADR 0015). That root
`Application` is the only thing kairos-configs ever creates directly —
everything else a cluster runs is defined here.

## Layout

```text
base/
└── <app>/                 # shared definition, no cluster-specific values
    ├── application.yaml
    └── kustomization.yaml
clusters/
├── k8s-dev/
│   ├── kustomization.yaml  # lists every app enabled on this cluster
│   └── apps/
│       └── <app>/           # only present for apps enabled on this cluster
│           ├── kustomization.yaml   # references ../../../../base/<app>
│           ├── version-patch.yaml   # per-cluster values
│           └── resources/           # per-cluster content, if the app has any
└── k8s-prod/
    ├── kustomization.yaml
    └── apps/
        └── <app>/
docs/
└── adr/                    # architecture decisions for this repo
```

Each cluster's root `Application` (bootstrapped by kairos-configs) syncs
`clusters/<cluster-name>/`. The `kustomization.yaml` sitting there makes
ArgoCD build that path as a Kustomize tree rather than a plain directory,
so root's own children are the rendered `Application` objects themselves —
one parent, several real children, matching ArgoCD's documented App of
Apps pattern (ADR 0005). An app is enabled for a cluster by a line in
that `resources:` list plus its `apps/<app>/` directory, and disabled by
their absence — not by a flag.

Each `clusters/<name>/apps/<app>/` is a small Kustomize overlay
referencing the app's shared definition under `base/<app>/` and patching
what is meant to differ per cluster. Two kinds exist:

- **Version-only** (`argocd`, `metallb`) — the overlay patches
  `spec.source.targetRevision`, nothing else.
- **Content-carrying** (`metallb-config`) — the overlay patches
  `spec.source.path` as well, pointing at its own `resources/`
  directory holding manifests that genuinely differ between clusters
  (ADR 0007).

Once rendered, each `Application` reconciles independently: one app's
*sync* failure does not affect another's. Note this is sync-time
isolation only — `clusters/<name>/` is a single Kustomize build, so a
malformed *overlay* fails the whole cluster's render.

See [`docs/adr/`](docs/adr/) for the reasoning behind this shape.

## Current state

| App | What it is | Per-cluster |
|---|---|---|
| `argocd` | ArgoCD manages itself, from its own official manifests (`manifests/cluster-install`), not the argo-helm chart (ADR 0004) | version |
| `metallb` | MetalLB in L2 mode, from upstream's `config/native` Kustomize directory — the clusters have no other `type: LoadBalancer` implementation (ADR 0006) | version |
| `metallb-config` | That cluster's `IPAddressPool` + `L2Advertisement` | address |

Bumping one cluster's version ahead of the other is a one-line change to
that cluster's `clusters/<name>/apps/<app>/version-patch.yaml`.

MetalLB addresses, each sitting directly above its cluster's kube-vip
control-plane VIP:

| Cluster | kube-vip VIP | MetalLB |
|---|---|---|
| `k8s-dev` | `192.168.1.11` | `192.168.1.12` |
| `k8s-prod` | `192.168.30.2` | `192.168.30.3` |
