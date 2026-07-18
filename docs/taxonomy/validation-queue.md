# Validation queue

The 36 candidates in `candidates-*.md` ranked for testbed validation. A
candidate becomes a catalog entry or a benchmark scenario only after the
fault is injected on the payments testbed and the signal is confirmed real.
Ranking favors: a clean deterministic signal, a fault that is common in
production, cheap injection on the existing testbed, and a signal class the
9-entry catalog does not already cover.

## Tier 1 - validate first (clean signal, new class, cheap inject)

1. **authz-scoped-allow-default-deny-gap** (security). A new remediation
   family: AuthorizationPolicy. Default-deny namespace plus a missing or
   too-narrow ALLOW rule produces a clean step-function of `response_code=403`.
   Common Istio authoring gotcha, one `kubectl apply` to inject. Highest
   value because it extends the catalog into a resource type it does not yet
   touch.
2. ~~**oom-kill-resource-limit** (client)~~. Moved to Deferred on
   validation. `OOMKilled` is object evidence, not a Prometheus signal, and
   the testbed's Prometheus (the stock Istio addon) does not scrape
   kube-state-metrics, so there is no `kube_pod_container_status_last_terminated_reason`
   series to trigger a scenario on. MeshMedic triggers scenarios on PromQL;
   a pod-status-only class needs kube-state-metrics added to the testbed
   first. Real finding, exactly what testbed validation is for.
3. **route-timeout-shorter-than-backend** (traffic). A route timeout below
   real backend latency floods `response_flags="UT"`, a clean mesh signal no
   current entry uses. Inject a VirtualService timeout under the payments
   TIMING env. Classic gotcha, cheap.
4. **jwt-requestauth-issuer-jwksuri-misconfig** (security). Clean
   `response_code=401` flood, a class the catalog has no coverage of. One
   RequestAuthentication plus one AuthorizationPolicy to inject.
5. **client-wrong-port** (client). Extends `traffic-vanished-triage`: proves
   the absence-signal + log-signature + rollout-diff dossier generalizes
   beyond the DNS typo to any wrong-target client deploy. Very cheap.

## Tier 2 - validate after tier 1 (clean but adjacent, or needs a small evidence add)

- ~~**subset-selector-zero-endpoints** (traffic)~~. Validated: the UH signal
  is already caught by `upstream-host-ejection-flood`, so it is not a new
  detection class. But the finding was worth the run: a broken subset
  selector and an ejection flood produce the identical UH flag with different
  fixes, and the existing entry's ejection patch is wrong for a selector
  mismatch. Resolved by enriching `upstream-host-ejection-flood` with
  DestinationRule object evidence (subsets + outlier policy) so a reviewer
  can tell the two apart, rather than adding a redundant entry. Two side
  findings: at a single broken subset (20% of traffic) the UH rate (~0.48
  rps) sits below the entry's threshold of 1, so only a full-service selector
  break fires it; and the entry's original `ejected-hosts` / `ready-endpoints`
  evidence uses `envoy_cluster_*` / kube-state metrics the stock addon does
  not scrape, so the kubectl-based object evidence is the part that actually
  resolves on this testbed.
- **fault-injection-left-in-production** (traffic): a forgotten
  fault-injection VirtualService; clean `response_flags` signal.
- **ztunnel-node-crashloop-blackhole** (ambient): the one clean "yes" in the
  ambient slice; inject by lowering the ztunnel DaemonSet memory limit.
  Touches `istio-system`, so slightly higher blast radius.
- **image-tag-bad-rollout** / **readiness-probe-misconfig** (client): both
  clean object signals, both rollout-diff root causes; strong triage
  extensions.
- **configmap-secret-startup-break** (client): `CreateContainerConfigError`,
  clean, new.
- **dependency-down-cascading-errors** (client): extends
  `error-surge-outlier-ejection` with a downstream-dependency root cause.
- **ambient-namespace-not-enrolled** (ambient): policy silently not applied,
  a class no request-metric tool sees; needs a label-object evidence type.
- **waypoint-missing-l7-noop** (ambient): L7 policy silently a no-op;
  `reporter="waypoint"` absence contrast.

## Deferred - real classes, not injectable on this testbed

Documented in the candidate files for the encyclopedia, but out of scope for
validation until the testbed grows:

- **networkpolicy-new-deny** (client): the testbed CNI is kindnet, which
  does not enforce NetworkPolicy. Needs a Calico/Cilium testbed.
- **oom-kill-resource-limit**, **image-tag-bad-rollout**,
  **readiness-probe-misconfig**, **configmap-secret-startup-break** (client):
  all pod-status classes whose signal is kube-state-metrics, which the stock
  Istio Prometheus addon does not scrape. Adding kube-state-metrics to the
  testbed would move this whole group into scope at once; a good testbed
  enhancement, out of scope for the current addon-only Prometheus.
- **multicluster-trust-domain-mismatch** (security): needs a second cluster.
- **destinationrule-loadbalancer-hotspot** (traffic): needs a load profile
  the single-node testbed cannot produce.
- **ambient-component-version-skew**, **ztunnel-redirection-lost-after-node-reboot**
  (ambient): no mesh signal by the candidates' own honest rating; would need
  a live remediation test rather than a metric.

## Do not implement (duplicates)

- **mtls-strict-sidecar-plaintext-caller** (security): fully covered by the
  existing `mtls-policy-conflict.yaml`. Kept in the candidate file only to
  document the L7-sidecar vs L4-ambient distinction.

## Coverage math

Of 36 candidates: 5 in tier 1, ~9 in tier 2, ~5 deferred for testbed
reasons, 1 duplicate, the rest lower-priority partials. Validating tiers 1
and 2 would take the catalog from 9 entries to roughly 20 and the benchmark
from 6 scenarios to 8-10, each one injected and observed rather than
assumed.
