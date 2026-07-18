# Candidates: traffic management

This slice covers VirtualService, DestinationRule, Gateway, and Sidecar
routing and resilience faults - the config objects that decide *where*
traffic goes and *how tolerant* the mesh is of the destination misbehaving,
as opposed to the identity/mTLS or capacity slices covered elsewhere. Nine
candidates follow, each checked against the existing 9-entry catalog
(`canary-latency-rollback`, `connection-pool-overflow`,
`error-surge-outlier-ejection`, `mtls-policy-conflict`,
`mtls-policy-conflict-ambient`, `retry-storm-damping`,
`traffic-vanished-triage`, `upstream-host-ejection-flood`,
`waypoint-overload-scale`) and grounded in real Istio GitHub issues or
istio.io docs. Two (`waypoint-binding-drops-l7-enforcement`,
`sidecar-egress-scope-blackhole`) are directly reproducible on the payments
testbed as shipped; one (`ingress-gateway-host-binding-mismatch`) is not,
since the testbed has no north-south `Gateway` object today, only the
ambient waypoint - that gap is disclosed in its own entry rather than
glossed over.

## subset-selector-zero-endpoints

- **Mechanism**: The DestinationRule's subset label selector for a version
  (e.g. `v2`) no longer matches any live pod - the selector was edited
  without updating the Deployment's pod-template labels, or vice versa  - 
  while the VirtualService still routes a nonzero weight to that subset.
  Envoy's EDS returns zero endpoints for the subset's cluster, so every
  request the VirtualService sends there fails at the proxy; it never
  reaches a pod.
- **Telemetry signature**: `istio_requests_total` with
  `response_flags="UH"` (no healthy upstream), scoped by
  `destination_version` to the broken subset only - the other subset keeps
  serving normally, so the overall service-level error ratio can look mild
  even though one subset is at 100% failure.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter=~"source|waypoint",
    destination_service_name="payments", destination_service_namespace="demo",
    destination_version="v2", response_flags="UH"}[2m]))
  ```
- **Inject sketch**:
  ```
  kubectl -n demo patch destinationrule payments --type=merge -p \
    '{"spec":{"subsets":[{"name":"v1","labels":{"version":"v1"}},
      {"name":"v2","labels":{"version":"v2","track":"canary-broken"}}]}}'
  ```
  No payments-v2 pod carries `track: canary-broken`, so the v2 subset now
  selects zero endpoints while the VirtualService's 20% weight to it is
  unchanged.
- **Triage signatures**: object diff - `DestinationRule.spec.subsets[].labels`
  compared against the Deployment's `spec.template.metadata.labels`; a
  subset selector with a key/value no live pod carries is the signature,
  checkable without touching the cluster.
- **Detectable deterministically?**: yes - the UH flag scoped by
  `destination_version` is a clean, unambiguous signal. Diagnosis needs one
  more step: disambiguating this from `upstream-host-ejection-flood` (same
  UH-family symptom) requires checking `kube_endpoint_address_available`
  (reports the subset's pods as Ready here, unlike a genuine outage) against
  the DestinationRule's subset labels (which show the mismatch).
- **Overlaps existing catalog?**: adjacent to `upstream-host-ejection-flood`
  - same response-flag family, different root cause. That entry assumes
  Kubernetes reports ready endpoints that outlier detection is wrongly
  ejecting, and its remediation (relax `maxEjectionPercent`) does nothing
  here, because there is no ejection happening - the subset's cluster is
  configured to be empty. This entry's fix is a subset-label correction, not
  a DestinationRule ejection-policy patch. New candidate.
- **Sources**: [istio/istio#24969](https://github.com/istio/istio/issues/24969)
  (DestinationRule subset with a selector that matches nothing),
  [istio/istio#18424](https://github.com/istio/istio/issues/18424) (missing
  endpoint for a subset despite the Service having Endpoints),
  [istio/istio#36237](https://github.com/istio/istio/issues/36237)
  (referenced host+subset not found).

## destinationrule-host-mismatch-silent-nogo

- **Mechanism**: An operator adds or edits a DestinationRule meaning to
  attach `trafficPolicy` (connection-pool limits, `portLevelSettings`,
  outlier detection) to a host, but `spec.host` has a typo, or a
  `portLevelSettings` entry names a port number the Service doesn't expose.
  DestinationRule host matching is an exact string match done at
  xDS-generation time with no validation-time cross-check against the
  Kubernetes Service registry, so the object is accepted, does nothing, and
  produces no error anywhere. Traffic keeps flowing exactly as it did before
  the change; the intended resiliency setting simply never exists.
- **Telemetry signature**: none. This is the template's explicit
  "no mesh signal" case - Envoy's config for the real cluster is unchanged,
  so no metric before-vs-after comparison can distinguish "policy applied"
  from "policy silently orphaned."
- **Signal draft (PromQL)**: n/a - object/log evidence only.
- **Inject sketch**:
  ```
  kubectl -n demo apply -f - <<'EOF'
  apiVersion: networking.istio.io/v1
  kind: DestinationRule
  metadata:
    name: payments-limits
    namespace: demo
  spec:
    host: paymets
    trafficPolicy:
      connectionPool:
        http:
          http1MaxPendingRequests: 1
  EOF
  ```
  `paymets` (typo) never resolves to the `payments` Service; hammering the
  service shows the "limit" has no effect at all.
- **Triage signatures**: object field - `DestinationRule.spec.host` string
  compared against every `Service.metadata.name` (`+ .namespace.svc.cluster.local`
  variants) in the same namespace; a DR host with no match is the signature.
  `istioctl analyze` also flags unresolved/unused DestinationRule references.
- **Detectable deterministically?**: partial - "no" from metrics (that is
  the danger of the class: it can sit for months with zero symptom); "yes"
  deterministically from a one-line object/string comparison or
  `istioctl analyze` output, so a config-diff pass reliably catches what a
  dashboard never will.
- **Overlaps existing catalog?**: new - none of the 9 entries check a
  DestinationRule's `host` field against the Service registry; the closest,
  `canary-latency-rollback`, assumes the subset/DR wiring is already correct
  and only reasons about latency once it is.
- **Sources**: istio.io common-problems guidance that a DestinationRule host
  typo produces silence rather than an error (referenced via
  [istio.io traffic management problems](https://istio.io/latest/docs/ops/common-problems/network-issues/));
  [istio/istio#31925](https://github.com/istio/istio/issues/31925) and
  [istio/istio#30730](https://github.com/istio/istio/issues/30730) for the
  compounded case (host mismatch across a VirtualService/DestinationRule/
  namespace boundary producing "cluster not found" instead of silence).

## route-timeout-shorter-than-backend-ut-floods

- **Mechanism**: A VirtualService route's `timeout` (or a retry's
  `perTryTimeout`) is set shorter than the backend's real p99 latency  - 
  common after a route is copied from a faster service, or after a backend
  regresses without its route timeout being revisited. Envoy cuts off every
  request that crosses the threshold itself, with a 504, even for requests
  that would otherwise have succeeded.
- **Telemetry signature**: `istio_requests_total` with
  `response_flags="UT"` (upstream request timeout) rising, alongside
  `istio_request_duration_milliseconds_bucket` showing the destination's
  real p99 sitting at or above the configured timeout value.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter=~"source|waypoint",
    destination_service_name="payments", destination_service_namespace="demo",
    response_flags="UT"}[2m]))
  ```
- **Inject sketch**:
  ```
  kubectl -n demo set env deploy/payments-v2 TIMING_50_PERCENTILE=3s
  kubectl -n demo patch virtualservice payments --type=merge -p \
    '{"spec":{"http":[{"route":[{"destination":{"host":"payments","subset":"v1"},"weight":80},
      {"destination":{"host":"payments","subset":"v2"},"weight":20}],"timeout":"1s"}]}}'
  ```
- **Triage signatures**: object field - `VirtualService.spec.http[].timeout`
  compared against `histogram_quantile(0.99, ...)` for the same
  `destination_version`; a route timeout set below its own destination's
  measured p99 is the smoking gun, checkable without any log access.
- **Detectable deterministically?**: yes - UT is a clean, specific flag, and
  the timeout-vs-p99 object comparison is a deterministic check with no
  inference required.
- **Overlaps existing catalog?**: new. `retry-storm-damping` covers retries
  amplifying a *real* degradation; this is close to the mirror case - a
  timeout that is wrong even though the backend would have succeeded, with
  no retries or amplification involved. No existing entry compares a route
  timeout value against measured latency.
- **Sources**: [istio.io request timeouts task](https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/)
  (a timeout under the backend's real latency produces 504s by design); UT
  flag semantics per Envoy's access-log response-flags documentation.

## fault-injection-left-in-production

- **Mechanism**: A VirtualService `HTTPFaultInjection` (`fault.abort` or
  `fault.delay`) added for chaos testing, or scoped to a test header, is
  never removed, or the header scope is dropped in a later edit and it
  starts matching all production traffic. It then behaves indistinguishably
  from a real incident: synthetic errors or synthetic latency, generated by
  the mesh itself with no involvement from the actual workload.
- **Telemetry signature**: `istio_requests_total` with
  `response_flags="FI"` (abort injected by fault filter) and
  `response_code` equal to the configured `abortHttpStatus`; for a
  delay-only fault, `response_flags="DI"` (delay injected) with a normal
  response code but `istio_request_duration_milliseconds_bucket` showing an
  artificial latency floor equal to the configured `fixedDelay`. Flagging
  explicitly: FI/DI are real, documented Envoy response flags, but they sit
  outside the UT/UO/UH/UF/URX/NR/DENY set named in this brief, so treat them
  as a secondary, less-commonly-referenced pair worth double-checking
  against your Envoy version before relying on them in a dashboard.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter=~"source|waypoint",
    destination_service_name="payments", destination_service_namespace="demo",
    response_flags="FI"}[2m]))
  ```
- **Inject sketch**:
  ```
  kubectl -n demo patch virtualservice payments --type=merge -p \
    '{"spec":{"http":[{"fault":{"abort":{"percentage":{"value":100},"httpStatus":503}},
      "route":[{"destination":{"host":"payments","subset":"v1"},"weight":80},
      {"destination":{"host":"payments","subset":"v2"},"weight":20}]}]}}'
  ```
- **Triage signatures**: object field - the mere presence of a
  `VirtualService.spec.http[].fault` block outside a scoped test-header
  match is itself the signature in a production VirtualService; rollout
  diff on the VirtualService names exactly which merge introduced it.
- **Detectable deterministically?**: yes - `response_flags="FI"`/`"DI"` is
  unambiguous once queried for, and the object evidence (the `fault` stanza
  itself) fully explains the symptom with no inference needed.
- **Overlaps existing catalog?**: new - none of the 9 entries check a
  VirtualService for a `fault` stanza.
- **Sources**: [istio.io fault injection task](https://istio.io/latest/docs/tasks/traffic-management/fault-injection/);
  [istio/istio#42862](https://github.com/istio/istio/issues/42862) (fault
  injection scoped to one namespace/ServiceEntry unexpectedly affecting
  others - the same "left wider than intended" risk); DI/FI flag semantics
  per [envoyproxy/envoy#295](https://github.com/envoyproxy/envoy/pull/295).

## waypoint-binding-drops-l7-enforcement

- **Mechanism**: In ambient mode, VirtualService/DestinationRule (L7) rules
  are enforced only for traffic whose Namespace, Service, or Pod carries an
  `istio.io/use-waypoint` label naming a live waypoint Gateway
  (`gatewayClassName: istio-waypoint`) whose own `istio.io/waypoint-for`
  scope covers that traffic type. If the label's value is edited to a name
  that no longer resolves (typo, or the Gateway is deleted/renamed during a
  waypoint upgrade), Istio does not error - it just stops routing that
  traffic through the waypoint. ztunnel keeps carrying the bytes at L4
  (mTLS still applies), but the VirtualService's weighted split and any
  DestinationRule policy silently stop being enforced: the payments Service
  quietly reverts to plain per-pod routing across both v1 and v2, e.g. a
  configured 80/20 split becomes an unweighted 50/50.
- **Telemetry signature**: absence, not a flag - `istio_requests_total`
  with `reporter="waypoint"` for `destination_service_name="payments"` stops
  advancing, while `istio_tcp_connections_opened_total` with
  `reporter="destination"` for the same destination keeps incrementing: L4
  keeps succeeding while L7 visibility and enforcement vanish together.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter="waypoint",
    destination_service_name="payments", destination_service_namespace="demo"}[2m]))
  # expect ~0 / no series, while:
  sum(rate(istio_tcp_connections_opened_total{reporter="destination",
    destination_service_name="payments", destination_service_namespace="demo"}[2m]))
  # stays > 0
  ```
- **Inject sketch**:
  ```
  kubectl label namespace demo istio.io/use-waypoint=nonexistent-waypoint --overwrite
  ```
  (or `kubectl -n demo delete gateway waypoint` to remove the bound object
  outright). Confirm loadgen's curls keep returning 200 throughout.
- **Triage signatures**: object field - the effective `istio.io/use-waypoint`
  value (namespace, then Service, then Pod, in override order) compared
  against `kubectl -n demo get gateway -o jsonpath='{.items[*].metadata.name}'`;
  a label value with no matching Gateway name is the signature.
  `istioctl waypoint list -n demo` also flags workloads with no attached
  waypoint.
- **Detectable deterministically?**: partial - like `traffic-vanished-triage`,
  this is an absence pattern (a specific label value's traffic disappearing)
  rather than a fired flag, so it needs the same "used to exist, now silent"
  comparison; diagnosis is a one-field object check once the absence is
  noticed, but nothing pages on a metric threshold alone.
- **Overlaps existing catalog?**: new, but a sibling to
  `traffic-vanished-triage`'s absence-detection pattern, and to
  `waypoint-overload-scale` (both concern waypoint health from different
  angles - that entry assumes the waypoint is attached and overloaded; this
  one is the case where the binding itself is broken and the waypoint is
  never engaged at all).
- **Sources**: [istio.io ambient waypoint usage](https://istio.io/latest/docs/ambient/usage/waypoint/)
  (binding precedence via `istio.io/use-waypoint`, `istio.io/waypoint-for`
  scoping); [istio.io ambient waypoint troubleshooting](https://istio.io/latest/docs/ambient/usage/troubleshoot-waypoint/).

## ingress-gateway-host-binding-mismatch

- **Mechanism**: A north-south `Gateway` resource's `spec.selector` doesn't
  match any running ingress workload's pod labels, so nothing ever programs
  its listeners - traffic never reaches an Istio-managed proxy at all. A
  related but distinct fault: the Gateway's `servers[].hosts` and the bound
  VirtualService's `spec.hosts`/`spec.gateways` disagree on the hostname,
  so TLS/HTTP negotiation succeeds but Envoy has no route for the Host
  header it receives.
- **Telemetry signature**: for the host-mismatch half,
  `istio_requests_total` with `response_flags="NR"` (no route configured)
  at the gateway's own `reporter="destination"` view. For the
  selector-mismatch half: nothing - the request never reaches an
  Istio-managed proxy, so this is an explicit "no mesh signal, check the
  Gateway/LB/DNS layer" case.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter="destination",
    response_flags="NR"}[2m]))
  ```
  (scope by the namespace hosting the gateway workload; n/a for the
  selector-mismatch half.)
- **Inject sketch**: **not reproducible on the payments testbed as
  shipped** - `manifests/payments.yaml` has no north-south `Gateway`
  object, only the ambient waypoint (see the previous entry). To reproduce,
  first add a `networking.istio.io/v1 Gateway` and a matching VirtualService
  binding for the payments Service, then either mismatch the Gateway's
  `selector` against the ingress pod's labels, or diverge
  `servers[].hosts` from the VirtualService's `spec.hosts`.
- **Triage signatures**: object field - `Gateway.spec.selector` vs the
  labels on the actual ingress-controller pods; `Gateway.spec.servers[].hosts`
  vs `VirtualService.spec.hosts`/`spec.gateways` string compare. Caution:
  `istioctl analyze` has shipped false positives on this exact selector
  check for otherwise-correct cross-namespace bindings (see sources) - treat
  its output as a lead, not proof.
- **Detectable deterministically?**: yes for the host-binding half (NR flag
  plus a one-line object diff); no for the pure selector-mismatch half  - 
  nothing ever becomes mesh telemetry, so it is only catchable from
  Gateway/LB-level object evidence, not a Prometheus query.
- **Overlaps existing catalog?**: new - none of the 9 entries touch a
  north-south Gateway object; the selector-mismatch half is conceptually a
  sibling of `traffic-vanished-triage`'s absence pattern, just one layer
  further upstream (before any mesh proxy is involved at all).
- **Sources**: [istio/istio#44430](https://github.com/istio/istio/issues/44430)
  and [istio/istio#38148](https://github.com/istio/istio/issues/38148)
  (selector-not-found analyzer false positives, real underlying
  selector-matching mechanics); [istio/istio discussion #52376](https://github.com/istio/istio/discussions/52376),
  [istio/istio#27080](https://github.com/istio/istio/issues/27080),
  [istio/istio#31557](https://github.com/istio/istio/issues/31557),
  [istio/istio#9429](https://github.com/istio/istio/issues/9429),
  [istio/istio#47942](https://github.com/istio/istio/issues/47942) (404 NR
  route_not_found from Gateway/VirtualService host mismatches).

## sidecar-egress-scope-blackhole

- **Mechanism**: A `Sidecar` resource scopes a workload's (or namespace's)
  egress to an explicit host allowlist (`spec.egress[].hosts`). Adding this
  incrementally, without including every host the workload legitimately
  calls, silently removes the omitted clusters from that workload's Envoy
  config. Calls to a now-out-of-scope host are not proxied anywhere: Envoy
  answers locally out of its synthetic `BlackHoleCluster` with a direct 502,
  without ever attempting the connection.
- **Telemetry signature**: `istio_requests_total` with
  `response_code="502"` and `destination_service_name="BlackHoleCluster"`
  (a synthetic Envoy cluster, not a real Kubernetes Service).
  `response_flags` on this metric is `"-"` (none set) - that is the
  documented, correct value here, not a gap in this signature.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter="source",
    source_workload_namespace="demo", destination_service_name="BlackHoleCluster"}[2m]))
  ```
- **Inject sketch**:
  ```
  kubectl -n demo apply -f - <<'EOF'
  apiVersion: networking.istio.io/v1
  kind: Sidecar
  metadata:
    name: restrict-egress
    namespace: demo
  spec:
    egress:
      - hosts:
          - "istio-system/*"
  EOF
  ```
  This omits `./payments.demo.svc.cluster.local` from the allowlist, so
  loadgen's calls to `payments` fall into `BlackHoleCluster` instead of the
  real Service.
- **Triage signatures**: object field - `Sidecar.spec.egress[].hosts` vs the
  set of Service names the workload's own prior `istio_requests_total`
  series shows it calling; a destination that used to appear as a normal
  `destination_service_name` and now only appears as `BlackHoleCluster`
  right after a Sidecar object's creation timestamp is the signature.
- **Detectable deterministically?**: yes - `destination_service_name="BlackHoleCluster"`
  is an exact, Istio-documented signature; no inference required once
  queried for.
- **Overlaps existing catalog?**: new - none of the 9 entries reference a
  Sidecar CRD or `BlackHoleCluster`.
- **Sources**: [istio.io - Monitoring Blocked and Passthrough External Service Traffic](https://istio.io/latest/blog/2019/monitoring-external-service-traffic/)
  (the `BlackHoleCluster`/502/`response_flags="-"` signature, straight from
  istio.io); [istio/istio#38556](https://github.com/istio/istio/issues/38556),
  [istio/istio#12237](https://github.com/istio/istio/issues/12237),
  [istio/istio#33387](https://github.com/istio/istio/issues/33387) (real
  egress-scoping mistakes and gaps).

## destinationrule-loadbalancer-hotspot

- **Mechanism**: A DestinationRule's `trafficPolicy.loadBalancer` is
  missing, or set to a policy that concentrates requests onto a fraction of
  a service's replicas instead of spreading them evenly - a consistent-hash
  policy keyed on a header the client never varies, or `LEAST_REQUEST`
  interacting badly with long-lived HTTP/2 connections. Every request still
  succeeds; there is no error, timeout, or ejection. The workload just runs
  hot on some replicas while the rest sit idle, until the hot pods fall over
  under real load.
- **Telemetry signature**: no single flag - the signature is derived:
  variance across `istio_requests_total` grouped by `destination_workload`
  (or, if per-endpoint granularity is scraped, by pod) far from the uniform
  share each replica should get.
- **Signal draft (PromQL)**:
  ```
  stddev(sum by (destination_workload) (rate(istio_requests_total{
    reporter=~"destination|waypoint", destination_service_name="payments",
    destination_service_namespace="demo"}[5m])))
  ```
  A first-cut variance query, not a settled threshold - see detectability
  below.
- **Inject sketch**:
  ```
  kubectl -n demo scale deploy/payments-v1 --replicas=3
  kubectl -n demo apply -f - <<'EOF'
  apiVersion: networking.istio.io/v1
  kind: DestinationRule
  metadata:
    name: payments
    namespace: demo
  spec:
    host: payments
    subsets:
      - name: v1
        labels: {version: v1}
      - name: v2
        labels: {version: v2}
    trafficPolicy:
      loadBalancer:
        consistentHash:
          httpHeaderName: "X-User"
  EOF
  ```
  loadgen never varies `X-User`, so all traffic to the (now 3-replica) v1
  subset pins onto a single pod.
- **Triage signatures**: object field - `DestinationRule.spec.trafficPolicy.loadBalancer`
  present, and its type (`consistentHash` vs `simple: ROUND_ROBIN`/`LEAST_REQUEST`),
  cross-checked against whether the calling client actually varies the hash
  key.
- **Detectable deterministically?**: no, on this testbed as shipped  - 
  `payments-v1`/`payments-v2` each run a single replica
  (`spec.replicas: 1` in `manifests/payments.yaml`), so there is nothing to
  hot-spot across until replicas are raised. Even after raising them, this
  is a real gap in the stock Prometheus addon: on ambient, `istio_requests_total`
  from the waypoint is labeled by `destination_workload`, not by individual
  pod or upstream host - the same limitation `error-surge-outlier-ejection.yaml`
  and `connection-pool-overflow.yaml` already disclose for cAdvisor/
  `envoy_cluster_*` metrics. This candidate is honestly "no confirmed mesh
  signal" until someone validates whether per-endpoint stats are scrapeable
  at all in this setup.
- **Overlaps existing catalog?**: new - none of the 9 entries look at
  intra-workload load distribution.
- **Sources**: [istio/istio#51642](https://github.com/istio/istio/issues/51642)
  (load imbalance since 1.22, `LEAST_REQUEST` leaving one pod an outlier);
  [istio/istio#45668](https://github.com/istio/istio/issues/45668)
  (loadBalancer trafficPolicy interactions); [istio.io DestinationRule reference](https://istio.io/latest/docs/reference/config/networking/destination-rule/)
  for the `consistentHash`/`simple` fields.

## virtualservice-weight-validation-gap

- **Mechanism**: A VirtualService's `HTTPRouteDestination.weight` field is
  removed or malformed by a manual edit (`kubectl edit`/`kubectl replace`, a
  bad template render, a merge conflict) in a way the validating webhook
  does not reject. Istio has shipped this producing either dropped/ignored
  route entries, or - in the worst documented case - an entirely empty
  routing table pushed to Envoy on its next restart, because istiod
  computed a zero-length `weighted_clusters` list that Envoy's own protobuf
  validation then rejects wholesale.
- **Telemetry signature**: the same absence-of-traffic signature as
  `traffic-vanished-triage` - `istio_requests_total` for the payments
  Service drops to ~0 after flowing normally. No distinguishing flag of its
  own; the value here is naming a specific, documented root cause behind
  that generic absence rather than a new signal.
- **Signal draft (PromQL)**: identical to `traffic-vanished-triage`'s signal
  query; n/a beyond that.
- **Inject sketch**:
  ```
  kubectl -n demo get virtualservice payments -o json \
    | jq 'del(.spec.http[0].route[1].weight)' \
    | kubectl -n demo replace -f -
  ```
  This mirrors the exact repro in istio/istio#50228: editing out one
  destination's `weight` bypasses the default-filling behavior a normal
  `kubectl apply` would otherwise trigger.
- **Triage signatures**: rollout diff - the previous VirtualService revision
  (already modeled as `rolloutEvidence` in `traffic-vanished-triage`) shows a
  `weight` key present; the current one shows it missing or `0`. That
  single-field diff is the whole diagnosis.
- **Detectable deterministically?**: partial - detection is already fully
  covered by `traffic-vanished-triage`'s absence signal and rollout-diff
  evidence; this entry adds no new query, only a named, real,
  GitHub-documented trigger (a validating-webhook gap on the `weight`
  field) worth surfacing explicitly rather than leaving as an unlabeled
  "bad rollout."
- **Overlaps existing catalog?**: extends `canary-latency-rollback` (same
  VirtualService weight surface, opposite trigger: authoring/validation bug
  vs. organic latency regression) and `traffic-vanished-triage` (same
  absence signal in the worst case). Flagging both so the maintainer can
  decide whether this deserves its own scenario or is fully subsumed by the
  existing pair.
- **Sources**: [istio/istio#36021](https://github.com/istio/istio/issues/36021)
  (a single misconfigured VirtualService emptied the whole routing table on
  Envoy restart); [istio/istio#50228](https://github.com/istio/istio/issues/50228)
  (validating webhook doesn't catch a missing `weight` edited via
  `kubectl edit`, `IST0106` "total destination weight = 0");
  [istio/istio#47177](https://github.com/istio/istio/issues/47177) (bad
  VirtualService config not blocked by the validating webhook despite
  `istioctl validate` having the check).
