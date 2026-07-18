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
- ~~**fault-injection-left-in-production** (traffic)~~. Validated and
  merged as `fault-injection-left-in-production` (catalog entry + scenario).
  FI response flag verified live at ~1.5 rps; distinct from a genuine 5xx
  surge, so it suppresses error-surge and is report-only (the object evidence
  pins the fault stanza to remove). End-to-end confirmed only it fires.
- ~~**ztunnel-node-crashloop-blackhole** (ambient)~~. Deferred: the signal is
  a pod restart/waiting-reason series, which is kube-state-metrics. The stock
  addon does not scrape it (same gap as the OOM group), so there is no
  Prometheus signal to trigger a scenario. Moves in with the pod-status group
  once kube-state-metrics is added to the testbed.
- ~~**image-tag-bad-rollout**, **readiness-probe-misconfig**,
  **configmap-secret-startup-break** (client)~~. Deferred with the pod-status
  group (see Deferred): all three trigger on kube-state-metrics the addon
  does not scrape. Their rollout-diff root cause would be caught by the
  triage layer, but the trigger signal is missing on this testbed.
- ~~**dependency-down-cascading-errors** (client)~~. Deferred: the payments
  testbed has no downstream dependency for the service to call, so a
  "dependency down" fault is indistinguishable from `error-surge` here (both
  are the service returning 5xx). Needs a testbed with a real downstream to
  separate a caller-side cause from the service's own errors. Original note:
  extends
  `error-surge-outlier-ejection` with a downstream-dependency root cause.
- ~~**ambient-namespace-not-enrolled** (ambient)~~. Deferred: a real,
  high-value class (policy silently not applied), but unenrolling the demo
  namespace removes the whole namespace from the ambient dataplane, nuking
  the very waypoint telemetry the testbed observes through, and its signal
  (waypoint metrics vanish while traffic still flows direct) overlaps the
  traffic-vanished absence signal. Distinguishing "bypassed" from "stopped"
  needs a namespace-enrollment-label object evidence added to
  traffic-vanished, and validating it cleanly needs a multi-namespace testbed
  where one workload is unenrolled while observability stays intact. Recorded
  as a planned enrichment, not a single-namespace-testbed validation.
- ~~**waypoint-missing-l7-noop** (ambient)~~. Deferred, same reason: the demo
  relies on the waypoint for its L7 metrics, so removing it to simulate a
  missing-waypoint namespace removes the observability the scenario would be
  measured through. Its `reporter="waypoint"` absence also overlaps
  traffic-vanished. Needs a testbed where an L7 policy is present but no
  waypoint enforces it, isolatable per-namespace.

Tier 2 is complete: subset-selector and fault-injection validated (one
enriched an existing entry, one became a new entry), the rest deferred with
documented findings above.

## Tier 3 - the remaining lower-priority partials

The candidates not selected into Tier 1 or Tier 2: mostly partial-detection
classes or ones needing infrastructure the testbed lacks. Split by whether
they can be validated on the current single-service ambient testbed.

### Tier 3a - validatable now (cheap, mostly triage generalizations)

1. ~~**client-wrong-scheme** (client)~~. Validated and merged (scenario +
   new TLS-error log patterns). loadgen speaking https to a plaintext port
   fails with curl 35 (TLS connect error); the triage entry now fires with
   the TLS-error signature and the http-to-https rollout diff. End-to-end
   confirmed. Third distinct wrong-target signature (NXDOMAIN, empty reply,
   TLS error).
2. ~~**client-wrong-namespace-qualified-name** (client)~~. Confirmed subsumed
   by client-dns-typo: `payments.wrong-ns` does not resolve, producing the
   same NXDOMAIN "could not resolve" signature the triage entry already
   catches. Same catalog entry, same patterns, same rollout-diff root cause;
   no new scenario needed.
3. ~~**authz-deny-rule-too-broad** (security)~~. Confirmed subsumed by
   authz-deny-flood: a too-broad DENY produces the same `response_code=403`
   flood at the waypoint that authz-deny-flood already fires on, and its
   object evidence already lists every AuthorizationPolicy so the reviewer
   sees which rule is over-broad. Same mechanism validated when authz-deny-flood
   was injected; no new entry needed (the subset-selector pattern: same
   signal, different narrative).

Tier 3 is complete: 3a processed (one new scenario, two confirmed subsumed),
3b deferred with documented findings below.

### Tier 3b - deferred on inspection (need infra the testbed lacks)

- **ingress-gateway-host-binding-mismatch** (traffic): needs an ingress
  Gateway; the testbed drives traffic from an in-cluster loadgen, no gateway.
- **sidecar-egress-scope-blackhole** (traffic): a sidecar-mode fault; the
  testbed is ambient (no sidecars).
- **waypoint-binding-drops-l7-enforcement** (traffic),
  **waypoint-pod-pending-unschedulable**, **ambient-cni-node-not-ready**,
  **ztunnel-istiod-xds-disconnect-stale-config**,
  **ztunnel-cert-renewal-premature-revocation** (ambient): pod-state or
  control-plane signals needing kube-state-metrics or a multi-node cluster,
  same gaps as the deferred groups below.
- **peerauth-portlevel-override-conflict**, **workload-cert-ca-ttl-expiry**,
  **custom-authz-extauthz-outage-coupling** (security): reuse existing
  mTLS/authz signals or need an external authz service; distinct root cause
  but no clean new signal to validate here.
- **destinationrule-host-mismatch-silent-nogo**,
  **virtualservice-weight-validation-gap** (traffic),
  **authz-selector-typo-silent-mismatch** (security): "silent" classes whose
  worst case has no telemetry at all (config accepted, traffic quietly
  misrouted or a security hole opened); catchable only by config-lint object
  evidence, not a runtime signal. Candidates for a future `istioctl analyze`
  style static-check evidence type.

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
