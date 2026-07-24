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
│   ├── <app>.yaml          # pointer Application, synced directly by the root Application
│   └── apps/
│       └── <app>/           # only present for apps enabled on this cluster
│           ├── kustomization.yaml   # references ../../../../base/<app>, patches per-cluster values
│           └── version-patch.yaml
└── k8s-prod/
    ├── <app>.yaml
    └── apps/
        └── <app>/
docs/
└── adr/                    # architecture decisions for this repo
```

Each cluster's root `Application` (bootstrapped by kairos-configs) syncs
`clusters/<cluster-name>/` directly, non-recursively — it only ever finds
the pointer `Application` files sitting at that top level, one per app
enabled for that cluster. An app is disabled for a cluster by the absence
of its pointer file and its `clusters/<name>/apps/<app>/` directory, not
by a flag.

Each pointer `Application` reconciles independently, on its own sync
cycle, pointing its own `source.path` at
`clusters/<name>/apps/<app>/` — a small Kustomize overlay referencing the
app's shared definition under `base/<app>/` and patching the fields that
are meant to differ per cluster (currently: application version). A
broken overlay for one app only affects that app's own `Application`
object; every other app's pointer keeps syncing normally.

See [`docs/adr/`](docs/adr/) for the reasoning behind this shape.

## Current state

One app: `argocd` — ArgoCD manages its own Helm release, on both
clusters, pinned to the same version today. Bumping one cluster's version
ahead of the other is a one-line change to that cluster's
`clusters/<name>/apps/argocd/version-patch.yaml`.
