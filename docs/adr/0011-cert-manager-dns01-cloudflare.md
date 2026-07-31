# 0011 — cert-manager with Cloudflare DNS-01, wired to the Gateway by annotation

- Status: Accepted
- Date: 2026-07-31

## Context

ADR 0009 put a Gateway API ingress in front of both clusters, with a single
HTTP listener on a wildcard hostname per cluster
(`*.k8s-<cluster>.home.fam-melcher.net`). Everything published through it is
plaintext. TLS is the next step, and it needs an issuer, an ACME solver and a
way to get the resulting Secret onto a listener.

## Problem

Three facts about this environment constrain the solution, and each was
measured rather than assumed.

1. **HTTP-01 cannot work.** The Gateway address is a MetalLB LAN address
   (192.168.30.3 on prod, 192.168.1.12 on dev, ADR 0006). Let's Encrypt
   validates HTTP-01 from the public internet. Nothing reaches these
   addresses from outside. DNS-01 is the only usable challenge type, and it
   is also the only one that can issue the wildcard the listener needs.

2. **The zone is split-horizon, and it breaks the DNS-01 self check.**
   `fam-melcher.net` is served by Cloudflare (`aria`/`ruben.ns.cloudflare.com`)
   and `home.fam-melcher.net` is *not* delegated away from it, so cert-manager's
   SOA walk lands on the right zone and no explicit zone configuration is
   needed. But the LAN resolver at 192.168.1.1 also answers for
   `home.fam-melcher.net` — it returns `192.168.30.3` for
   `*.k8s-prod.home.fam-melcher.net` and, critically, answers
   `TXT _acme-challenge.k8s-prod.home.fam-melcher.net` with NOERROR/NODATA
   rather than forwarding it. Cluster DNS follows the node resolver, so
   cert-manager's self check would query the LAN resolver, see no TXT record,
   and never present the challenge to Let's Encrypt. This does not time out
   into a useful error — it simply never converges.

3. **The Cloudflare API token cannot be in git.** ADR 0010 accepted one
   out-of-band Secret (`ceph-csi-rbd-credentials`) and said to revisit when a
   second appeared. This is the second.

## Decision

**Two Applications, matching the split already used for MetalLB.**
`base/cert-manager` installs the Jetstack chart (`charts.jetstack.io`, chart
`cert-manager`, `targetRevision: v1.21.1` — chart version tracks appVersion 1:1
and carries a leading `v`). `base/cert-manager-config` points back at this repo
and carries the ClusterIssuers as per-cluster content (ADR 0007), with the same
`retry` + `SkipDryRunOnMissingResource` posture `metallb-config` uses and for
the same reason (ADR 0008): nothing can order it against the install.

**`helm.values` lives in the base, not the overlay.** ADR 0010 put
ceph-csi-rbd's values in the overlay because they were genuinely per-cluster —
fsid, mon endpoint, pool. None of cert-manager's values are. The overlay
carries `targetRevision` only. The rule is unchanged: values that differ per
cluster go in the overlay, values that do not stay in the base.

**`dns01RecursiveNameserversOnly: true`.** This is the direct consequence of
problem 2 above, and it is not optional here — without it issuance hangs
indefinitely. The cost is that the self check now depends on public resolver
caching and can be slower.

The resolver list is three operators, two addresses each: Quad9
(`9.9.9.9`, `149.112.112.112`), Cloudflare (`1.1.1.1`, `1.0.0.1`) and DNS4EU
(`86.54.11.100`, `86.54.11.200`, the unfiltered variant — the protective ones
carry blocklists that have no business inspecting a challenge name). Google's
resolvers, which cert-manager would otherwise fall back to as its compiled-in
default, are deliberately not among them. dns0.eu, Mullvad and digitalcourage
were tested and do not answer from this network at all.

Cloudflare is on the list despite already being a single point of failure for
this setup — it holds the zone and receives every challenge record through its
API, so its resolver learns nothing it does not already store — but it is not
first, because Cloudflare's resolver has a visible outage history and the
operators before it do not.

What the extra operators actually buy is narrow, and worth stating precisely:
cert-manager iterates this list and breaks on the first server that *responds*
(`pkg/issuer/acme/dns/util/wait.go`), not on the first server that returns the
record. A NODATA answer from Quad9 ends the walk. So the list covers one
failure only — an operator being unreachable — which is exactly the failure
being defended against.

**`ServerSideApply=true`.** Measured on the rendered v1.21.1 chart, per ADR
0003's rule that a sync option is present because something requires it:
`clusterissuers.cert-manager.io` is 325,798 bytes, `issuers.cert-manager.io`
325,660, `challenges.acme.cert-manager.io` 269,173 — all above client-side
apply's 262,144-byte limit.

**`startupapicheck.enabled: false`.** The chart ships it as a
`helm.sh/hook: post-install` Job, which ArgoCD replays as a PostSync hook on
every sync. It is an install-time smoke test; a recurring one that can mark
the app degraded buys nothing that ArgoCD's own retry does not already give.

**Certificates come from the Gateway annotation, not from a `Certificate` in
git.** `config.gatewayAPI.enabled: true` on the controller, plus
`cert-manager.io/cluster-issuer` on each cluster's Gateway. cert-manager builds
one Certificate per listener that has a hostname, `tls.mode: Terminate` and a
same-namespace `certificateRef`, naming the Certificate after the Secret. The
existing HTTP listener has no `tls` block and is skipped.

The alternative — an explicit `Certificate` next to the Gateway, with no
Gateway API integration and no extra controller RBAC — was considered and
rejected. It keeps the object in git and visible in ArgoCD, at the cost of
restating the listener's hostname and secret name in a second file that must be
kept in step by hand. The annotation makes the listener the single source of
truth for both.

**Production issuer on prod, staging on dev.** Both ClusterIssuers exist on
both clusters; only the Gateway annotation differs. `k8s-dev` is torn down
routinely and would burn Let's Encrypt's duplicate-certificate limit
(5 per identical name set per week) on the same wildcard. Its chain is
untrusted and browsers will warn — that is the accepted trade.

**No ACME contact email.** `spec.acme.email` is a plain string in the
ClusterIssuer schema — cert-manager offers no `emailSecretRef` and no other
indirection, so setting it means committing a personal address that identifies
an account at a third party, in a repo where it is then permanent. The field is
optional, and since 2025-06-04 it also does nothing: Let's Encrypt ended
expiration notification emails, citing the privacy cost of retaining addresses
tied to issuance records. The residual loss is that Let's Encrypt has no way to
reach this account about a CA-side incident such as a mass revocation. That is
accepted — such events are public, and the field can be added later, since
cert-manager documents it as updatable after registration.

**The Cloudflare token stays out-of-band**, a `Secret` named
`cloudflare-api-token` with key `api-token` in the `cert-manager` namespace
(the default `clusterResourceNamespace`, where ClusterIssuer secret references
resolve regardless of which namespace the Certificate lives in), applied with
`kubectl`. Revisiting ADR 0010's open question and deciding *not* to introduce
sealed-secrets or SOPS yet: both of these are bootstrap-time credentials
applied once per cluster build, not application secrets that grow with the
workload count. When a secret appears that belongs to a workload rather than to
the cluster's own plumbing, that is the trigger.

## Consequences

- **Fresh-provision ordering hazard, and it does not self-heal.** cert-manager
  checks for the Gateway API CRDs *once, at controller startup*; upstream's own
  documentation prescribes `kubectl rollout restart deployment cert-manager -n
  cert-manager` when the CRDs arrive afterwards. Nothing orders `cert-manager`
  against `envoy-gateway` (ADR 0008), so on a from-scratch cluster cert-manager
  can win the race, come up without the Gateway watch, and then sit there
  healthy and idle: no Certificate, no error. Symptom is a Gateway with an
  annotation and no Certificate object at all. Remedy is the rollout restart,
  once, and it belongs in the provisioning runbook. Both existing clusters
  already run envoy-gateway, so this only bites a rebuild.
- The Certificate and the TLS Secret are created by cert-manager and are not in
  git. ArgoCD does not track or prune them; they appear in the resource tree as
  children of the Gateway.
- Certificate contents cannot be validated by `kustomize build`. What the repo
  can be checked for is the listener shape the shim requires — hostname
  present, `mode: Terminate`, same-namespace `certificateRef`.
- Rotating the Cloudflare token means re-applying the Secret by hand on both
  clusters. Nothing in this repo records that it happened.
- An issuer swap (staging to production on dev, say) is a one-line annotation
  change plus deleting the old Secret so a fresh order is placed.

## Rationale

The two constraints that shaped this — no public HTTP reachability and a
split-horizon zone — both point at the DNS-01 solver, and the second one is
the kind of environment fact that produces a silent hang rather than an error
message. Recording it here is most of the value of this ADR: the
`dns01RecursiveNameserversOnly` line in `base/cert-manager/application.yaml`
looks like a preference and is not.
