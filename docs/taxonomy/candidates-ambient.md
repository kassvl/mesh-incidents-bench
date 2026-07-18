# Candidate taxonomy: ambient infrastructure (ztunnel / waypoint / CNI / xDS)

Ambient mode moves the data plane out of the request path and into shared,
per-node infrastructure (ztunnel) plus optional per-namespace L7 proxies
(waypoints), wired up by an out-of-process CNI plugin and driven by istiod's
control-plane push. That split creates a failure category the existing
MeshMedic catalog does not cover yet: faults where the *infrastructure that
would enforce or measure policy is itself missing, unhealthy, or
disconnected*, so the mesh looks calm not because nothing is wrong but
because nothing is being watched. The two existing ambient entries
(`waypoint-overload-scale`, `mtls-policy-conflict-ambient`) both assume the
infrastructure is present and working, just under load or enforcing a
conflicting policy; every candidate below instead asks "is the ambient
control/data-plane component even there and doing its job", which is why
several are honestly rated only partially or not-at-all detectable from
request-shaped metrics - that gap is the territory this file is scouting.
Each candidate below is grounded in at least one real istio/istio or
istio/ztunnel GitHub issue or an istio.io doc page.

## ambient-namespace-not-enrolled

- **Mechanism**: The `demo` namespace (or a workload in it) is missing the
  `istio.io/dataplane-mode=ambient` label - never applied, removed by a
  templating error, or overwritten by a GitOps sync from a values file that
  predates ambient onboarding. Istio's ambient controller only programs CNI
  redirection for pods whose pod-or-namespace carries that label (and lacks
  `sidecar.istio.io/status` / `istio.io/dataplane-mode=none`). Without it,
  `istio-cni-node` never sets up the pod's iptables/eBPF redirect to
  ztunnel, so every connection to and from the workload's pods is plain
  Kubernetes networking: no mTLS, no L4/L7 policy, no ztunnel telemetry  - 
  and no error, because nothing rejected the traffic, it was simply never
  seen by the mesh. AuthorizationPolicies and PeerAuthentications targeting
  the namespace silently do nothing.
- **Telemetry signature**: Total absence of `istio_tcp_connections_opened_total`
  / `istio_tcp_connections_closed_total` / `istio_requests_total` for the
  affected `destination_service_namespace`, while `kube_pod_status_ready`
  shows the pods healthy and (if app-level metrics or logs exist) the
  application itself is serving traffic normally.
- **Signal draft (PromQL)**:
  ```
  (kube_pod_status_ready{namespace="demo", condition="true"} > bool 0)
  and on()
  (sum(rate(istio_tcp_connections_opened_total{destination_service_namespace="demo"}[5m])) or vector(0)) < bool 0.01
  ```
  This only flags "pods ready but zero ztunnel-observed connections"; it
  cannot by itself distinguish a missing label from a ztunnel/CNI outage
  (candidates below) - that disambiguation needs the object evidence.
- **Inject sketch**: On the payments testbed, remove the ambient label to
  simulate a drifted enrollment: `kubectl label ns demo
  istio.io/dataplane-mode-` (the trailing `-` deletes the label), then
  restart `payments-v1`/`payments-v2` so the pods come up unenrolled
  (ambient redirection is set at pod admission, not live-patched onto
  running pods). Loadgen keeps calling the Service and keeps getting 200s  - 
  that is the point of the fault.
- **Triage signatures**: `kubectl get pod -n demo -o
  jsonpath='{.items[*].metadata.annotations.ambient\.istio\.io/redirection}'`
  returns empty instead of `enabled`; `kubectl get ns demo -o
  jsonpath='{.metadata.labels}'` is missing `istio.io/dataplane-mode`;
  `istioctl x workload list` / `istioctl zc workload` (ztunnel-config) does
  not list the pod at all.
- **Detectable deterministically?**: partial - the absence-of-telemetry
  pattern is checkable (same shape as `traffic-vanished-triage`'s "traffic
  used to flow, now silent" logic), but absence alone has multiple possible
  causes (this label, ztunnel down, CNI down); confirming *this* cause
  requires reading the namespace/pod labels and the redirection annotation,
  which is object evidence, not a metric.
- **Overlaps existing catalog?**: adjacent to `mtls-policy-conflict-ambient`
  (both are about missing mesh enrollment) but inverted: that entry is a
  client without identity hitting a STRICT destination and getting an
  audible `DENY` at L4; this one is the destination itself never being
  captured, so there is no denial event and no telemetry at all. New as a
  distinct class.
- **Sources**: [istio.io - Add workloads to the mesh](https://istio.io/latest/docs/ambient/usage/add-workloads/) (label semantics and precedence rules); [istio/istio#45461 - ambient namespace default dataplane mode does not work](https://github.com/istio/istio/issues/45461); [istio/istio#50355 - Ambient: should use `istio.io/dataplane-mode=ambient` for enrolling individual pods](https://github.com/istio/istio/issues/50355); [Troubleshooting Istio Ambient wiki](https://github.com/istio/istio/wiki/Troubleshooting-Istio-Ambient) (redirection annotation check).

## waypoint-missing-l7-noop

- **Mechanism**: An operator writes an L7 `AuthorizationPolicy` (path/method/
  header match) or an HTTP `Route` for a namespace, correctly assuming
  ambient's L7 features, but no waypoint proxy is actually deployed for
  that namespace/service (or the service/workload was never labelled
  `istio.io/use-waypoint`). ztunnel enforces L4-only policy and silently
  ignores any rule it cannot evaluate at L4; the L7 rule is accepted by the
  API server (it is valid YAML) and simply never reaches an enforcement
  point. Traffic keeps flowing exactly as if the policy did not exist.
- **Telemetry signature**: `istio_requests_total{reporter="waypoint", ...}`
  is entirely absent for the destination (no waypoint ever reports on this
  traffic), while `istio_requests_total{reporter="destination", ...}`
  (ztunnel's L4-only view) shows normal 200s for requests that the L7 policy
  should have blocked or rewritten.
- **Signal draft (PromQL)**:
  ```
  sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments", destination_service_namespace="demo"}[5m])) or vector(0)
  ```
  A sustained `0` here while `reporter="destination"` traffic for the same
  service is non-zero is the tell; there is no single query that also
  confirms an L7 policy object exists and targets this workload - that part
  needs object evidence.
- **Inject sketch**: On the payments testbed, apply an L7
  `AuthorizationPolicy` (e.g., deny `GET /admin`) targeting the `payments`
  workload in `demo` **without** ever creating a waypoint Gateway or adding
  `istio.io/use-waypoint: <name>` to the Service/namespace. Loadgen and any
  manual `curl payments.demo:9090/admin` keep succeeding.
- **Triage signatures**: `kubectl get gateway -n demo -l
  'gateway.networking.k8s.io/gateway-class=istio-waypoint'` returns nothing;
  the Service/namespace has no `istio.io/use-waypoint` label;
  `istioctl waypoint list -n demo` reports no waypoint for the namespace;
  `istioctl proxy-status` never lists a waypoint proxy for `demo` at all
  (distinct from `waypoint-pod-pending-unschedulable`, where one exists but
  isn't `PROGRAMMED`).
- **Detectable deterministically?**: partial - the `reporter="waypoint"`
  absence plus `reporter="destination"` presence is a real, checkable
  metric contrast, but it only becomes a diagnosis once matched against the
  object evidence that an L7-only policy exists and expects a waypoint;
  metrics alone can't tell "no L7 policy configured" (harmless) from "L7
  policy configured but silently unenforced" (this fault).
- **Overlaps existing catalog?**: new - `waypoint-overload-scale` assumes a
  waypoint exists and is receiving traffic; this is the case where one
  never existed.
- **Sources**: [istio/istio#43576 - Authz policy not enforced with waypoint](https://github.com/istio/istio/issues/43576); [istio/istio#54275 - Istio Ambient - DENY L7 AuthorizationPolicy not working](https://github.com/istio/istio/issues/54275); [istio/istio#58432 - Waypoint proxy not intercepting service traffic despite correct configuration in ambient mesh (Istio 1.27.1)](https://github.com/istio/istio/issues/58432); [istio.io - Troubleshoot issues with waypoints](https://istio.io/latest/docs/ambient/usage/troubleshoot-waypoint/).

## ztunnel-node-crashloop-blackhole

- **Mechanism**: The ztunnel DaemonSet pod on one node enters
  `CrashLoopBackOff` (bad config push, panic, or `OOMKilled` under
  connection-table growth) and Kubernetes keeps restarting it. While it is
  down, every ambient-enrolled pod scheduled on that node loses mTLS, L4
  authorization, and - depending on how the CNI redirect degrades on
  ztunnel's socket disappearing - outbound connectivity entirely, because
  ztunnel is the only process actually holding the workload's sockets on
  that node. This blast radius is per-node, not per-service, which is what
  makes it confusing: two replicas of the same Deployment on different
  nodes can show completely different health.
- **Telemetry signature**: `kube_pod_container_status_waiting_reason{namespace="istio-system", pod=~"ztunnel-.*", reason="CrashLoopBackOff"}` and/or
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` for
  the ztunnel pod on the affected node; correlated with per-node service
  telemetry going to zero only for the replicas scheduled there (a partial,
  node-scoped version of the "traffic vanished" pattern).
- **Signal draft (PromQL)**:
  ```
  kube_pod_container_status_restarts_total{namespace="istio-system", pod=~"ztunnel-.*"} > 5
  ```
  paired with checking which `payments-*` pod is co-located on the same
  node (`kube_pod_info{namespace="demo"}` joined on `node`) to explain why
  only some replicas are affected.
- **Inject sketch**: On the payments testbed, drop the ztunnel DaemonSet's
  memory limit low enough to trigger OOM under the loadgen's connection
  churn, or `kubectl exec` a forced panic isn't available, so more
  realistically: `kubectl -n istio-system patch daemonset ztunnel --type
  merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","resources":{"limits":{"memory":"16Mi"}}}]}}}}'`
  and let the node's ztunnel pod OOMKill/crashloop.
- **Triage signatures**: `kubectl -n istio-system get pod -l app=ztunnel -o
  wide` shows one pod `CrashLoopBackOff` while others are `Running`;
  `kubectl -n istio-system logs <ztunnel-pod> --previous` shows the panic or
  OOM kill message; `kubectl describe pod <ztunnel-pod> -n istio-system`
  shows `Last State: Terminated, Reason: OOMKilled`.
- **Detectable deterministically?**: yes - `kube_pod_container_status_*`
  restart/waiting-reason series are standard kube-state-metrics output
  (already relied on by `upstream-host-ejection-flood`'s sibling queries in
  this catalog) and directly name the failing pod and reason, no log
  scraping required to detect it, only to explain the trigger.
- **Overlaps existing catalog?**: new - no existing entry covers
  infrastructure-pod health; the two ambient entries assume ztunnel is up.
- **Sources**: [istio/istio#52937 - Istio Ambient mode - ztunnel is not working in EKS](https://github.com/istio/istio/issues/52937); [istio/istio#48949 - Ambient L4 ztunnel Stability Solution](https://github.com/istio/istio/issues/48949); [How to Handle ztunnel Pod Failures in Ambient Mode](https://oneuptime.com/blog/post/2026-02-24-how-to-handle-ztunnel-pod-failures-in-ambient-mode/view) (OOMKilled diagnosis and memory-limit remediation pattern).

## ambient-cni-node-not-ready

- **Mechanism**: The `istio-cni-node` DaemonSet pod on a node fails to
  reach Ready (iptables rule installation errors, a container-runtime CNI
  chaining problem, or a race during CNI upgrade) but Kubernetes still
  schedules new pods onto that node because nothing in the default
  scheduler understands CNI-plugin readiness (istio-cni does not yet
  implement the CNI `STATUS` verb kubelet could use to gate scheduling).
  Any ambient pod that lands there never gets its traffic redirect
  programmed: it runs, passes its own liveness probe, and is completely
  invisible to the mesh - worse than the crashloop case above because nodes
  can be *silently* CNI-broken for a long time with no pod ever failing to
  start.
- **Telemetry signature**: no ambient-specific metric; visible only as
  `kube_pod_status_ready{namespace="istio-system", pod=~"istio-cni-node-.*"}
  == 0` for the node's CNI pod, combined with the same "ready pod, zero
  ztunnel telemetry" absence pattern as the label-missing candidate above,
  scoped to one node instead of one namespace.
- **Signal draft (PromQL)**:
  ```
  kube_pod_status_ready{namespace="istio-system", pod=~"istio-cni-node-.*", condition="true"} == 0
  ```
  Root-causing which application pods are actually affected needs more than
  this query: joining pod-to-node placement (`kube_pod_info`) against the
  CNI pod's unready window is object evidence, not a single mesh signal,
  and every ztunnel/istiod request-based dashboard stays green throughout.
- **Inject sketch**: Not cleanly reproducible with a manifest edit alone
  (the fault is in the CNI plugin's runtime state, not a CR); closest
  `inject.sh`-style approximation on the testbed: `kubectl -n istio-system
  delete pod -l app=istio-cni-node --field-selector
  spec.nodeName=<node>` right before scheduling a new `payments` replica
  onto that node, racing the DaemonSet's restart against the new pod's
  admission (matches the upstream-reported race conditions).
- **Triage signatures**: `kubectl -n istio-system get pod -l
  app=istio-cni-node -o wide` shows `0/1 Ready` on the affected node;
  `kubectl -n istio-system logs -l app=istio-cni-node
  --field-selector spec.nodeName=<node>` shows iptables or CNI-chaining
  errors; the affected application pod's
  `ambient.istio.io/redirection` annotation is missing even though the
  namespace carries the ambient label (distinguishing this from the
  label-missing candidate, where the annotation is absent because the
  label is).
- **Detectable deterministically?**: partial - CNI pod readiness is a
  standard metric, but confirming that a *specific* application pod was
  scheduled during the unready window and is therefore uncaptured needs
  object evidence (pod scheduling timestamp vs. CNI pod restart timestamp);
  no ztunnel or istiod metric names this condition on its own.
- **Overlaps existing catalog?**: new - adjacent to
  `ambient-namespace-not-enrolled` in symptom (uncaptured traffic) but the
  cause and the object evidence needed to confirm it are entirely
  different (node-level CNI state vs. a label).
- **Sources**: [istio/istio#55139 - Nodes get irregularly unusable](https://github.com/istio/istio/issues/55139) ("istio-cni can become non-ready, and furthermore ztunnel becomes non-ready because it relies on istio-cni"); [istio/istio#57360 - istio-cni-node failed start due to iptables rules issues](https://github.com/istio/istio/issues/57360); [istio/istio#53160 - istio-cni plugin should implement CNI STATUS verb](https://github.com/istio/istio/issues/53160); [istio/istio#49009 - Istio CNI agent upgrades](https://github.com/istio/istio/issues/49009) (race between CNI upgrade and new pod scheduling).

## waypoint-pod-pending-unschedulable

- **Mechanism**: The waypoint Deployment for a namespace cannot get a pod
  scheduled - insufficient node resources, a restrictive
  `PodDisruptionBudget`/anti-affinity, or a missing `ResourceQuota`
  headroom - and sits `Pending` indefinitely. `istioctl proxy-status` shows
  the waypoint's `PROGRAMMED` column as `Unknown`/`False`. Any L7 policy or
  routing that depends on this waypoint is unenforced exactly like
  `waypoint-missing-l7-noop`, except here a Gateway object *does* exist
  (so a naive "does a waypoint Gateway exist" check gives a false sense of
  safety) and, in some configurations, Service traffic that ambient decided
  should route through the waypoint can 503 outright because the intended
  next hop has no running endpoint.
- **Telemetry signature**: no waypoint-reporter request metrics at all for
  the namespace (same absence as the L7-noop case) plus, if traffic is
  being routed toward the (non-existent) waypoint endpoint,
  `istio_requests_total{response_flags=~"UH|NR"}` from the caller's side as
  it finds no healthy upstream for the waypoint's HBONE endpoint.
- **Signal draft (PromQL)**:
  ```
  kube_pod_status_phase{namespace="demo", pod=~".*-istio-waypoint-.*", phase="Pending"} > bool 0
  ```
  This detects the Kubernetes-level symptom; the ambient-specific
  consequence (`PROGRAMMED=Unknown`) is only visible via `istioctl
  proxy-status`, which is not a Prometheus series.
- **Inject sketch**: On the payments testbed, deploy a waypoint for `demo`
  (`istioctl waypoint apply -n demo`) then immediately starve it:
  `kubectl -n demo patch deployment demo-istio-waypoint --type merge -p
  '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","resources":{"requests":{"cpu":"64","memory":"64Gi"}}}]}}}}'`
  so it can never be scheduled, then apply an L7 policy expecting it.
- **Triage signatures**: `kubectl get pod -n demo -l
  gateway.networking.k8s.io/gateway-name=demo-istio-waypoint` shows
  `Pending`; `kubectl describe pod` on it shows
  `FailedScheduling`/insufficient-resource events; `istioctl proxy-status`
  lists the waypoint with `PROGRAMMED: Unknown` or does not list it as
  synced.
- **Detectable deterministically?**: partial - pod-phase `Pending` is a
  standard, queryable signal, but the ambient-specific confirmation
  (`PROGRAMMED` state, and that this waypoint was the intended enforcement
  point for a specific policy) is `istioctl`/object evidence, not a metric.
- **Overlaps existing catalog?**: new, but closely related to
  `waypoint-missing-l7-noop` in effect (silent non-enforcement); listed
  separately because the object evidence and remediation differ (fix
  scheduling vs. deploy/label a waypoint that never existed) and because a
  Gateway object being present but unschedulable is a materially different
  triage path than no Gateway existing at all.
- **Sources**: [istio/istio#53637 - pod can not use waypoint](https://github.com/istio/istio/issues/53637) (waypoint pod stuck `Pending`, `PROGRAMMED: Unknown`); [istio.io - Troubleshoot issues with waypoints](https://istio.io/latest/docs/ambient/usage/troubleshoot-waypoint/) (`istioctl proxy-status` PROGRAMMED check as the primary diagnostic).

## ztunnel-istiod-xds-disconnect-stale-config

- **Mechanism**: ztunnel's gRPC/xDS connection to istiod (port 15012) drops
  and does not reconnect cleanly - DNS resolution failure for the istiod
  Service, a `NetworkPolicy` that starts blocking 15012, or istiod being
  overloaded/slow enough that ztunnel's workload-fetch times out. ztunnel
  keeps serving whatever workload/policy/cert state it already cached, so
  it does not fail closed; it fails *stale*. A PeerAuthentication or
  AuthorizationPolicy change made after the disconnect never reaches that
  ztunnel instance, and identities for newly-created pods are never
  learned, so new pods on that node can't get certs and existing policy
  changes silently don't take effect there while everywhere else in the
  mesh they do.
- **Telemetry signature**: on the control-plane side, istiod's own
  `pilot_xds_pushes` (by `type` label) stalls or drops for the affected
  ztunnel client, and `pilot_xds_push_errors` increments; ztunnel-side there
  is no clean Prometheus counter for "I am running on stale config" - it
  shows up as an absence of expected policy effects plus explicit gRPC
  connection error log lines.
- **Signal draft (PromQL)**:
  ```
  sum(rate(pilot_xds_push_errors[5m])) > 0
  ```
  Flagged as **unverified against this testbed**: unlike the ztunnel TCP
  metrics in `docs/ambient-l4-denial-telemetry.md` (confirmed live on
  1.24.1), `pilot_xds_pushes`/`pilot_xds_push_errors` are istiod-side
  metrics on port 15014 documented in Istio's control-plane monitoring
  guidance and source (`pilot/pkg/xds/monitoring.go`), not something this
  benchmark has scraped and confirmed yet. Treat the query as a first cut
  to validate, not a ground truth.
- **Inject sketch**: On the payments testbed, add a `NetworkPolicy` in
  `istio-system` that denies egress from the ztunnel DaemonSet pods to
  istiod's pod IP on port 15012, then change a PeerAuthentication in `demo`
  and confirm ztunnel on the affected node never enforces it while ztunnel
  on other nodes does.
- **Triage signatures**: `kubectl -n istio-system logs ds/ztunnel --since=5m
  | grep -i "xds\|grpc connection error\|failed to lookup address"`; the
  known error text is `gRPC connection error connecting to
  https://istiod.istio-system.svc:15012: ... dns error` or `context
  deadline exceeded` while waiting for a workload resource; `istioctl
  proxy-status` shows the ztunnel's `SYNCED` column stale relative to
  `NonceSent`/`NonceAcked`.
- **Detectable deterministically?**: partial - istiod's own xDS push
  metrics are real and can show the control plane is unhappy in aggregate,
  but pinning the failure to one specific ztunnel instance running stale
  config needs its logs (grep above) or `istioctl proxy-status`, and this
  benchmark hasn't verified the istiod metrics are scraped by the stock
  Prometheus addon the way ztunnel's own port-15020 metrics are.
- **Overlaps existing catalog?**: new - the only xDS/control-plane-health
  candidate in either this file or the existing 9 catalog entries.
- **Sources**: [istio/istio#54912 - [ambient] ztunnel dns error, failure to connect to istiod](https://github.com/istio/istio/issues/54912); [istio/istio#53308 - Ztunnel XDS client connection error: gRPC connection error](https://github.com/istio/istio/issues/53308); [istio/ztunnel#1362 - istio ambient with ztunnel on premise - XDS client connection error](https://github.com/istio/ztunnel/issues/1362); [istio/istio pilot/pkg/xds/monitoring.go](https://github.com/istio/istio/blob/master/pilot/pkg/xds/monitoring.go) (defines `pilot_xds_pushes`, `pilot_xds_push_errors`); [Tracking the Golden Signals for Istio's Control Plane - Solo.io](https://www.solo.io/blog/golden-signals-istio-control-plane).

## ztunnel-cert-renewal-premature-revocation

- **Mechanism**: ztunnel's workload certificate (SPIFFE/SDS via istiod) is
  due for rotation, and the renewal call fails (istiod transient error,
  CA backpressure). In affected versions, ztunnel removes the still-valid
  old certificate from its in-memory store as soon as renewal is attempted,
  instead of only after the new one is confirmed, so the workload is left
  with no usable identity mid-renewal and every mTLS connection it
  originates or accepts fails until the next successful renewal - a
  self-inflicted outage from a transient control-plane hiccup, not a real
  security event.
- **Telemetry signature**: a burst of `istio_tcp_connections_closed_total`
  with `response_flags` indicating connection failure and
  `connection_security_policy="mutual_tls"` (the workload *did* have mesh
  identity, it just lost its valid cert mid-flight - distinguishing this
  from the `unknown`/`DENY` signature of an unenrolled client in
  `mtls-policy-conflict-ambient`), correlated to a narrow time window
  around the cert's expiry/rotation timestamp.
- **Signal draft (PromQL)**:
  ```
  sum by (source_workload, destination_workload) (rate(istio_tcp_connections_closed_total{destination_service_namespace="demo", connection_security_policy="mutual_tls"}[2m]))
  ```
  compared against a same-query baseline from 30 minutes earlier
  (`traffic-vanished-triage`'s `offset` pattern) to isolate a spike that
  coincides with a cert-rotation boundary rather than organic errors.
- **Inject sketch**: Not reproducible via manifest alone on a healthy
  testbed (needs an actual CA/renewal failure); closest approximation:
  shorten workload cert TTL aggressively via `PILOT_CERT_PROVIDER`/mesh
  config for `demo`, then briefly interrupt istiod availability
  (`kubectl -n istio-system scale deploy/istiod --replicas=0` for one
  rotation window, then back to `1`) so a renewal attempt lands inside the
  gap.
- **Triage signatures**: `kubectl -n istio-system logs ds/ztunnel --since=5m
  | grep -i "cert\|renew"` shows a renewal failure immediately followed by
  removal of the prior valid cert for the workload's identity; timing lines
  up with the certificate's documented TTL, not with any policy or
  PeerAuthentication change (ruling out `mtls-policy-conflict-ambient`).
- **Detectable deterministically?**: partial - the TCP-closed telemetry
  contrast (`mutual_tls` policy but connections still failing) is a real,
  queryable signal, but confirming the root cause is cert renewal rather
  than, say, a network blip requires the ztunnel log grep; there is no
  dedicated cert-rotation-failure counter exported today.
- **Overlaps existing catalog?**: new - distinct from
  `mtls-policy-conflict-ambient` because the failing party has mesh
  identity and a valid PeerAuthentication; the fault is entirely on the
  identity-issuance side, not policy.
- **Sources**: [istio/istio#56452 - Ambient - ztunnel prematurely removes valid certificates on renewal failure, causing service disruption](https://github.com/istio/istio/issues/56452).

## ambient-component-version-skew

- **Mechanism**: During a rolling upgrade, istiod is bumped but the
  ztunnel DaemonSet, `istio-cni-node` DaemonSet, or a namespace's waypoint
  (pinned to an old revision tag) is left more than the supported one-minor-
  version behind, or upgraded out of the documented order (Istio requires
  istiod to be upgraded before ztunnel/CNI, with ztunnel allowed to lag by
  at most one minor version). Outside that window, xDS schema or behavior
  changes between the skewed components can produce silent feature gaps
  (a new policy field istiod sends that old ztunnel ignores), outright
  rejection of config, or a crash at reconnect - and because ambient
  upgrades touch istiod, ztunnel, CNI, and waypoints as four separate
  rollout steps, it is easy for one to lag without anyone noticing until
  it's paged.
- **Telemetry signature**: no dedicated "version skew" metric; visible as
  `istio_build{component="ztunnel"}`/`istio_build{component="pilot"}`
  (or `istioctl version --output json` for waypoints) reporting minor
  versions more than one apart, alongside symptoms that mimic the other
  candidates in this file (stale config, unenforced policy) depending on
  which xDS field triggered the incompatibility.
- **Signal draft (PromQL)**:
  ```
  n/a - object/log evidence only. `istio_build` is a per-component info
  metric (value always 1, version in labels), so a skew check is a label
  comparison across two series, not a threshold query; the current
  benchmark tooling does not have a comparator for that.
  ```
- **Inject sketch**: On the payments testbed, upgrade istiod two minor
  versions (e.g. `istioctl install --set revision=new-minor`) while leaving
  the `ztunnel` DaemonSet and any `demo` waypoint pinned to the old
  revision tag, then apply a PeerAuthentication feature only understood by
  the newer istiod's xDS output.
- **Triage signatures**: `istioctl version` shows istiod and
  data-plane-component versions diverging by more than one minor release;
  `kubectl -n istio-system get pods -l app=ztunnel -o
  jsonpath='{.items[*].spec.containers[*].image}'` vs. the istiod image tag
  disagree; ztunnel or waypoint logs show xDS decode/validation errors
  right after the istiod upgrade completes.
- **Detectable deterministically?**: no - there is no mesh-native signal
  that says "these two components are on incompatible versions"; it is
  purely an object/image-tag comparison the operator (or MeshMedic) has to
  perform explicitly, which is exactly the kind of check request-metric
  tooling has no reason to run.
- **Overlaps existing catalog?**: new - none of the 9 entries touch
  upgrade/version state.
- **Sources**: [istio.io - Upgrade with Helm (ambient)](https://istio.io/latest/docs/ambient/upgrade/helm/) (documents the supported skew: control plane upgraded before ztunnel, within one minor version); [istio/istio#49009 - Istio CNI agent upgrades](https://github.com/istio/istio/issues/49009) (corner cases where new ambient pods appear while CNI is mid-upgrade).

## ztunnel-redirection-lost-after-node-reboot

- **Mechanism**: A node reboots (kernel update, spot reclaim, node-pool
  cycling) without first being drained. `istio-cni-node` and ztunnel come
  back up, but the iptables/eBPF redirection rules that were previously
  programmed for already-running pods are not re-established for pods that
  survive the reboot without being recreated - kubelet reattaches them to
  the same sandbox, so no new pod-admission event fires the CNI's
  redirect-setup path. Those pods keep running, keep passing kubelet
  probes, keep holding valid certs from before the reboot, and their
  traffic silently stops going through ztunnel (bypasses port 15008/HBONE
  entirely) and instead hits raw pod networking, where it may then be
  blocked or allowed inconsistently by any NetworkPolicy that assumed mesh
  redirection was in effect.
- **Telemetry signature**: none from the mesh's own metrics - the upstream
  report is explicit that `istioctl ztunnel-config workload` still lists
  the pod as enrolled, certs are valid, and no mTLS errors appear anywhere;
  the only observable change is the affected pod's traffic quietly
  disappearing from ztunnel's TCP counters while the pod itself stays
  `Running` and `Ready`.
- **Signal draft (PromQL)**:
  ```
  n/a - object/log evidence only. The closest proxy is the same
  "ready pod, zero ztunnel-reported traffic" contrast used in
  ambient-namespace-not-enrolled, but here `istioctl ztunnel-config
  workload` reports the pod as correctly enrolled, so even that comparison
  requires cross-referencing the node's last reboot/uptime against the
  pod's traffic history, not a single query.
  ```
- **Inject sketch**: Hard to trigger via manifest on the payments testbed
  (needs an actual node reboot); closest fleet-realistic approximation:
  `kubectl -n istio-system delete pod -l app=istio-cni-node
  --field-selector spec.nodeName=<node>` without deleting/recreating the
  `payments` pod already running on that node, simulating the CNI
  restarting under a still-alive workload pod whose redirect rules aren't
  replayed.
- **Triage signatures**: `istioctl ztunnel-config workload | grep
  payments` shows the pod as enrolled (rules out
  `ambient-namespace-not-enrolled`); `kubectl get node <node> -o
  jsonpath='{.status.conditions}'` or `uptime`/boot-time near the incident
  start; no error lines in ztunnel or application logs at all - the
  reported fix is `kubectl -n istio-system rollout restart daemonset
  istio-cni-node`, which immediately restores traffic, itself a triage
  signature (if a CNI restart fixes it with zero config change, this was
  the cause).
- **Detectable deterministically?**: no - the upstream issue reporter
  states plainly that no mTLS errors, no cert problems, and correct
  `ztunnel-config workload` enrollment are all present; the only working
  detection path is inferring from node reboot timing plus the "quiet
  traffic drop on an otherwise-healthy pod" absence, then confirming by
  testing whether a CNI DaemonSet restart fixes it. This is the honest
  "needs object/log + a live remediation test, no metric names it" case
  the ambient territory is expected to produce.
- **Overlaps existing catalog?**: new, and related to but distinct from
  `ambient-namespace-not-enrolled`: same symptom shape (uncaptured
  traffic) but the enrollment metadata is *correct*, which is precisely
  what makes this one harder - checking the label/annotation (the fix for
  the other candidate) gives a clean bill of health here.
- **Sources**: [istio/istio#60882 - [Ambient] Traffic bypasses ztunnel (no HBONE/15008) for existing pods after node reboot without drain](https://github.com/istio/istio/issues/60882).
