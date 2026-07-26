# 0006 — MetalLB in L2 mode as the LoadBalancer implementation

- Status: Accepted
- Date: 2026-07-26

## Context

`kairos-configs` provisions these clusters with both of k3s's packaged
networking components disabled: `--disable=traefik` **and**
`--disable=servicelb` (`configs/roles/10-server-init.yaml`,
`10-server-join.yaml`). kube-vip is deployed, but with `cp_enable: "true"`
and `svc_enable: "false"` (`configs/cluster/15-kube-vip.yaml`) — it owns the
control-plane VIP and nothing else.

The consequence had not been written down anywhere: **these clusters have no
`type: LoadBalancer` implementation at all.** A Service requesting an external
address stays `<pending>` indefinitely, because nothing is watching for it.

This surfaced while planning Gateway API + Envoy Gateway, which creates one
`type: LoadBalancer` Service per `Gateway`. That work is blocked until an
address can actually be assigned.

## Problem

How does a `type: LoadBalancer` Service get an address on these clusters?

## Considered Alternatives

1. **Re-enable k3s ServiceLB** (drop `--disable=servicelb` in
   `kairos-configs`). Two one-line changes. Rejected: it contradicts a
   deliberate provisioning decision, requires a node roll on both clusters,
   and makes node ports 80/443 exclusive cluster-wide.
2. **kube-vip's own service mode** (`svc_enable: "true"`). Superficially the
   cheapest option — kube-vip is already deployed, so it looked like
   LoadBalancer support for zero new components. It is not: **kube-vip does no
   IPAM.** It advertises addresses that are already populated in a Service's
   spec; it does not allocate them. Automatic allocation requires the
   separately-installed `kube-vip-cloud-provider`, configured through a
   `kube-system` ConfigMap, whose last release (v0.0.12) is from 2025-05-01.
   The apparent saving evaporates, and it would couple control-plane HA and
   data-plane addressing into one component.
3. **kube-vip service mode *plus* MetalLB.** Rejected outright: both announce
   over ARP on the same L2 segment. Two answerers for one address is a
   split-brain that presents as intermittent connectivity rather than a clean
   failure. A variant (MetalLB for IPAM, kube-vip for advertisement) is
   undocumented by either project and rests on unverified assumptions about
   which Service field kube-vip reads.
4. **`EnvoyProxy` with `envoyService.type: NodePort`.** No LoadBalancer
   controller at all. Rejected as the general answer: non-standard ports, and
   it pushes an alpha API (`gateway.envoyproxy.io/v1alpha1`) into a repo that
   otherwise pins stable ones. Remains a reasonable temporary probe.
5. **Cilium LB-IPAM.** Not available: these clusters run k3s's default
   flannel CNI, not Cilium.
6. **MetalLB in L2 mode.** Chosen.

## Decision

MetalLB, **L2 mode** (ARP), pinned to `v0.16.1`, installed from MetalLB's own
upstream Kustomize directory `config/native` in `github.com/metallb/metallb`.

L2 rather than BGP: this is a flat home network with no router-side BGP
configuration, and L2 mode requires nothing outside the cluster.

`config/native` rather than the Helm chart, for two measured reasons:

- At chart `0.16.1`, `frrk8s.enabled` defaults to **true**. An Application
  passing no values installs an frr-k8s DaemonSet, a second
  `ValidatingWebhookConfiguration` and four unused CRDs on a deployment that
  is explicitly L2-only. `config/native` is native by construction — verified
  by building it: 9 CRDs, 1 webhook configuration, 1 Deployment, 1 DaemonSet,
  no frr-k8s.
- The chart ships neither the `metallb-system` Namespace nor its PodSecurity
  labels. `config/native` ships the Namespace already carrying
  `pod-security.kubernetes.io/{enforce,audit,warn}: privileged`, which the
  speaker needs (host networking, `NET_RAW`) if PodSecurity is ever enforced
  on these clusters. No such enforcement exists today; the labels are free
  insurance that the chart does not provide.

It also matches the shape `base/argocd` already uses — an upstream Kustomize
directory pinned to a tag — rather than introducing a second packaging style.

### Addressing

One address per cluster, expressed as an explicit `/32`:

| Cluster | kube-vip control-plane VIP | MetalLB pool |
|---|---|---|
| `k8s-dev` | `192.168.1.11` | `192.168.1.12/32` |
| `k8s-prod` | `192.168.30.2` | `192.168.30.3/32` |

The two clusters are on different segments; `k8s-prod` additionally sits
behind a routed path with a sub-1500 MTU
(`kairos-configs/clusters/k8s-prod/config/14-net-mtu.yaml`), so nothing about
its addressing is derivable from `k8s-dev`'s.

`*.k8s-prod.home.fam-melcher.net` already resolves to the prod address. The
dev equivalent is not set up yet.

### Sync configuration

- **No `ServerSideApply`.** Measured on the built artifact: the largest CRD is
  `bgppeers.metallb.io` at 11,584 bytes — 4.4% of client-side apply's
  262,144-byte annotation limit. ADR 0003's rule is that a sync option is
  present because something requires it.
- **No `CreateNamespace=true` on either Application.** `config/native` owns
  `metallb-system`. Two owners for one object is ADR 0004's failure mode.
- **Pre-emptive `ignoreDifferences`** on
  `ValidatingWebhookConfiguration/metallb-webhook-configuration`'s
  `.webhooks[]?.clientConfig.caBundle`, scoped by name. The shipped manifest
  contains **zero** `caBundle` occurrences, and MetalLB's controller holds
  `patch`/`update` on that specific object. The drift is therefore certain,
  not speculative — the app would be permanently `OutOfSync` from first sync
  without it. Scoping by name matters: an unnamed entry would silently exempt
  every `ValidatingWebhookConfiguration` in the cluster.

## Consequences

- `type: LoadBalancer` works on both clusters. Gateway API + Envoy Gateway is
  unblocked.
- **Address deconfliction is the only mitigation available** for MetalLB and
  kube-vip both answering ARP on the same segment. `L2Advertisement` supports
  `nodeSelectors`, which would normally keep announcement off the node holding
  the VIP — but every node on both clusters is a control-plane node running
  kube-vip (`kairos-configs` ADR 0006), so there is nowhere to move it to.
  Keeping the pool a single explicit `/32` rather than a range makes it
  structurally hard to widen over the VIP by accident.
- Widening a pool later is a one-line change **only if** the neighbouring
  addresses are still free. Reserve a slightly wider block at the router than
  the pool declares.
- One address means one `Gateway`. A second `Gateway` — the likely trigger is
  splitting internal from internet-facing exposure — needs a second address
  **and** deterministic assignment, because with `autoAssign: true` the
  allocation order between two Services is not guaranteed. If the two ever
  swapped, an external port-forward would silently point at the internal
  gateway. `IPAddressPool.spec.serviceAllocation` is the lead to investigate
  when that happens; it may allow pinning without annotating Envoy's
  generated Service, and therefore without the alpha `EnvoyProxy` CR.
- MetalLB's declared `kubeVersion` is `>= 1.19.0-0` — a floor with no ceiling,
  so unlike the Envoy Gateway pin this is not half of a coupled version pair
  with `kairos-configs`'s Kubernetes version.

## Rationale

The decision looked like a choice between "add a component" and "turn on
something already deployed," and on that framing kube-vip wins easily. It
stops being that framing once you check what `svc_enable` actually does:
kube-vip advertises, it does not allocate, and the component that allocates is
a separate, stale project configured outside this repo. The real comparison is
between a documented, supported path and an improvised one — and this repo's
ADR 0003 and ADR 0004 are both records of what improvising costs.
