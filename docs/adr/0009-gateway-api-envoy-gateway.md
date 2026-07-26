# 0009 — Gateway API + Envoy Gateway for ingress

- Status: Accepted
- Date: 2026-07-26

## Context

These clusters have no ingress. k3s's packaged Traefik is disabled at
provisioning time (`kairos-configs/configs/roles/10-server-init.yaml`), so
nothing terminates north-south HTTP traffic today. [ADR
0006](0006-metallb-l2-loadbalancer.md) supplied the missing prerequisite: a
`type: LoadBalancer` implementation, one address per cluster.

## Problem

What terminates north-south HTTP traffic, and via which API?

## Considered Alternatives

1. **Re-enable k3s's packaged Traefik.** Zero work, but it implements the
   Ingress API, and it would be a component this repo inherited rather than
   chose.
2. **ingress-nginx.** Mature, but also Ingress API. The Kubernetes project's
   own direction is Gateway API; Ingress is feature-frozen.
3. **Envoy Gateway with Gateway API.** Chosen.

## Decision

Envoy Gateway `v1.8.3`, installed from its OCI Helm chart
(`docker.io/envoyproxy`, chart `gateway-helm`), implementing **Gateway API
only** — no `networking.k8s.io/v1 Ingress` resources and not Envoy Gateway's
Ingress-compatibility mode.

Two Applications, matching the shape ADR 0006 established:

- `envoy-gateway` — the upstream chart: controller, its own CRDs, the Gateway
  API CRDs, and a `ValidatingAdmissionPolicy`.
- `gateway` — this repo's `GatewayClass` and per-cluster `Gateway`, via a
  patched `spec.source.path` (ADR 0007).

One `Gateway` per cluster, HTTP only, in `envoy-gateway-system`, with a
wildcard listener derived from that cluster's own `dns` value in
`kairos-configs`:

| Cluster | Listener hostname | Address |
|---|---|---|
| `k8s-dev` | `*.k8s-dev.home.fam-melcher.net` | `192.168.1.12` |
| `k8s-prod` | `*.k8s-prod.home.fam-melcher.net` | `192.168.30.3` |

`ServerSideApply=true` on the chart Application, measured rather than assumed:
the rendered `envoyproxies.gateway.envoyproxy.io` CRD is 1,352,991 bytes,
`httproutes` 533,244, `securitypolicies` 484,902 — all far over client-side
apply's 262,144-byte annotation limit. Contrast `base/metallb`, whose largest
CRD is 11,584 bytes and which therefore does not set it (ADR 0003's rule).

`helm.skipCrds` is not set. The chart ships all 20 CRDs in a Helm `crds/`
directory and ArgoCD includes them by default; skipping would drop Envoy
Gateway's own CRDs too, and nothing else installs them.

No `EnvoyProxy` CR. The chart's default Service type is `LoadBalancer`, which
is exactly what MetalLB now satisfies — so the alpha
`gateway.envoyproxy.io/v1alpha1` API stays out of this repo.

### Accepted deliberately

**Gateway API ships at experimental channel, bundle v1.5.1.** The chart
bundles the CRDs and there is **no chart value that selects the standard
channel** — the only CRD knob is all-or-nothing, and disabling it would drop
Envoy Gateway's own CRDs as well, meaning this repo would have to own both CRD
sets and their version pairing. Upstream recommends standard *"as it will
provide a stable experience"*, and says experimental *"makes no backwards
compatibility guarantees."* Accepted because the API surface actually used
here — `GatewayClass`, `Gateway`, `HTTPRoute`, all `v1` — is identical in both
channels; experimental only adds resources this repo does not use. Revisit if
`TCPRoute`/`TLSRoute` or alpha fields are ever adopted.

**The chart installs a cluster-wide `Deny`-mode `ValidatingAdmissionPolicy`**
(`safe-upgrades.gateway.networking.k8s.io`) matching all CRD writes, which
blocks installing Gateway API CRDs below v1.5.0 or experimental-over-standard.
Kept — it is a real guard against an accidental downgrade. Recorded here
because it is cluster-scoped, chart-owned, and its own Helm `lookup`-based
ownership check never fires under `helm template`, so ArgoCD always renders it.

### Cluster-scoped inventory this change adds

20 CRDs, ClusterRole + ClusterRoleBinding, ValidatingAdmissionPolicy +
Binding, MutatingWebhookConfiguration, GatewayClass.

## Consequences

- Ingress exists. `HTTPRoute`s attach to the cluster's `Gateway` and share its
  address; adding routes does not consume MetalLB addresses.
- **Kubernetes version and Envoy Gateway version are now a coupled pair.**
  Envoy Gateway v1.8 supports Kubernetes v1.32–v1.35; these clusters build at
  v1.35, the top edge. The next `K8S_VERSION` bump in `kairos-configs` moves
  them out of the support matrix. Same class of cross-repo coupling ADR 0004
  documents for the ArgoCD tag.
- Ordering follows ADR 0008: convergence by retry, not sync waves. On a fresh
  provision `gateway` may fail a sync until the chart's CRDs register.
  Separately, Envoy's Service sits `<pending>` and the `Gateway` stays
  un-`Programmed` until MetalLB assigns an address — no sync failure, and it
  self-corrects.
- `*.k8s-dev.home.fam-melcher.net` does not exist yet and must be created
  pointing at `192.168.1.12`. The prod record already exists.
- **`allowedRoutes.namespaces.from: All` means anyone able to create an
  `HTTPRoute` in any namespace can publish on the cluster's Gateway.** That is
  acceptable while the address is LAN-only. It is *not* acceptable once the
  address is reachable from the internet: Envoy routes on the Host header and
  has no notion of which network a request arrived from, so port-forwarding
  this address would expose every hostname the listener accepts — a request
  with `Host: git.…` would be served regardless of the DNS name used to reach
  it. Before anything is port-forwarded, internet-facing traffic must move to
  a **second `Gateway`** with its own MetalLB address, an **exact** (not
  wildcard) listener hostname, and a restricted `allowedRoutes` selector. A
  second address also needs deterministic assignment, since `autoAssign` does
  not guarantee which Service gets which address across a rebuild.

## Rationale

Traefik and ingress-nginx both implement an API the Kubernetes project is
moving away from. Gateway API is the successor, and Envoy Gateway implements
it natively rather than translating to it — while Envoy itself is the data
plane underneath most service meshes, so the knowledge transfers.

The experimental-channel acceptance is the uncomfortable part of this
decision, and it is recorded as a decision rather than left as a chart default
precisely because it was not obvious: the channel is not selectable, and the
alternative costs more than it saves at this scale.
