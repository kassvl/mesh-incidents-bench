# Candidates: client-side / config-change failures

These nine candidates share the shape that makes `client-dns-typo` and
`traffic-vanished-triage` useful: the watched service (`payments`) is
healthy the whole time, so no threshold over `istio_requests_total`,
latency histograms, or response-flag counters can fire on the real cause.
The fault sits one layer above the mesh - a bad client rollout, a policy
object, a startup-time config error, a scheduler-visible resource event  - 
and the mesh's only honest contribution is silence or a misleading surge.
Three extend the DNS-typo family with a different wrong-target flavor (wrong
port, wrong scheme, wrong namespace-qualified name); one is a NetworkPolicy
block (flagged with the kindnet caveat below); one is a downstream
dependency outage that *does* produce a mesh signal but the wrong one to act
on; and four are plain Kubernetes object-state faults (ConfigMap/Secret,
image tag, probe, OOM) that the triage layer's rollout-diff and log-sweep
machinery can reach only if it grows a container-status evidence type it
does not have yet. Every inject sketch below targets `payments-v1`/`v2`,
`loadgen`, or the `payments`/`payments-db` Services in the `demo` namespace,
Istio 1.24 ambient, matching the existing scenarios.

## client-wrong-port

- **Mechanism**: A `loadgen` rollout changes the target URL to the correct
  host on the wrong port (e.g. `http://payments:9091/` instead of
  `:9090`). The Service `payments` resolves fine via DNS; the TCP `connect()`
  reaches a real cluster IP but nothing listens on that port, so the kernel
  answers with RST immediately. This is the same "wrong-target" family as
  `client-dns-typo` but fails one step later in the connection sequence
  (after name resolution, before a request is ever framed), which is exactly
  why the log signature differs.
- **Telemetry signature**: absence of traffic - identical shape to
  `client-dns-typo`. `istio_requests_total` for `payments` flatlines because
  the request never reaches a workload the mesh instruments.
- **Signal draft (PromQL)**: reuses the absence-of-traffic signal already in
  `traffic-vanished-triage.yaml` verbatim, scoped to `payments`/`demo`:
  `((sum(rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments", destination_service_namespace="demo"}[2m])) or vector(0)) < bool 0.05) * (max_over_time((sum(rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments", destination_service_namespace="demo"}[2m])) or vector(0))[30m:1m]) > bool 0.5)`
- **Inject sketch**:
  ```
  kubectl -n demo patch deploy/loadgen --type=json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/args",
       "value":["while true; do curl -s -o /dev/null http://payments:9091/; sleep 0.2; done"]}]'
  kubectl -n demo rollout status deploy/loadgen --timeout=60s
  ```
- **Triage signatures**: log sweep on `loadgen` shows
  `curl: (7) Failed to connect to payments port 9091: Connection refused`  - 
  regex `connection refused` (already in the existing log-pattern list, so
  this fires on the current sweep unmodified). `describe deploy/loadgen`
  / rollout diff shows the port digit change in
  `spec.template.spec.containers[0].args`. Distinguishing regex vs
  DNS-typo: **no** "could not resolve" / "name or service not known" line
  appears at all - resolution succeeded, connection did not.
- **Detectable deterministically?**: yes - absence signal plus an
  already-covered log regex plus a one-line rollout diff pin the cause
  without ambiguity.
- **Overlaps existing catalog?**: extends `traffic-vanished-triage`
  directly; no new evidence type needed, only a documented note that
  "connection refused" here means wrong-port, not wrong-policy.
- **Sources**: [Kubernetes Connection Refused: Root Cause in Under 5 Minutes](https://markaicode.com/errors/kubernetes-connection-refused-fix/) (targetPort/containerPort mismatch as a named connection-refused cause); [Avoiding Service Port Mismatches in Kubernetes](https://support.tools/kubernetes-service-port-mismatches/); `scenarios/client-dns-typo/ground-truth.md` (sibling fault this extends).

## client-wrong-scheme

- **Mechanism**: A `loadgen` rollout changes the URL scheme, e.g. to
  `https://payments:9090/` while `payments` (fake-service) only serves
  plaintext HTTP on 9090. curl attempts a TLS handshake against a socket
  that immediately sends an HTTP response line; the handshake fails before
  any HTTP request is framed. The inverse (an `http://` client hitting a
  TLS-only port) fails the same way in the other direction. This is
  client-caused and distinct from the mesh-level version of this bug family
  - a Service port renamed without an `http-`/`tcp-` prefix or a missing
  `appProtocol`, which makes Istio itself misclassify the protocol (see
  Sources) - because here the workload and Service are untouched; only the
  caller's scheme is wrong.
- **Telemetry signature**: absence of traffic, same shape as
  `client-dns-typo` and `client-wrong-port`.
- **Signal draft (PromQL)**: identical absence-of-traffic query as above,
  scoped to `payments`/`demo`.
- **Inject sketch**:
  ```
  kubectl -n demo patch deploy/loadgen --type=json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/args",
       "value":["while true; do curl -sk -o /dev/null https://payments:9090/; sleep 0.2; done"]}]'
  kubectl -n demo rollout status deploy/loadgen --timeout=60s
  ```
- **Triage signatures**: log sweep on `loadgen` shows curl TLS errors  - 
  regex candidates `ssl`, `tls`, `wrong version number`, `empty reply from
  server` (curl exit 35/52). `certificate` and `tls handshake` are already
  in `traffic-vanished-triage`'s pattern list and would catch a fraction of
  clients' phrasing, but "empty reply from server" and "wrong version
  number" are not covered and should be added. Rollout diff shows the
  `https://` substring appear in the container args.
- **Detectable deterministically?**: partial - the absence signal and
  rollout diff are solid, but the log regex is client-library-dependent
  (curl's wording differs from a Python `requests` or Go `net/http` TLS
  error), so the pattern list needs to grow per client runtime rather than
  matching one universal string.
- **Overlaps existing catalog?**: extends `traffic-vanished-triage`; its
  `certificate`/`tls handshake` patterns partially cover this today, two
  more patterns close the gap.
- **Sources**: [Istio / Traffic Management Problems](https://istio.io/latest/docs/ops/common-problems/network-issues/) (protocol selection from port name / `appProtocol`, the mesh-side sibling of this bug); [503 response when port name is prefixed with https- (mTLS enabled) · Issue #22124](https://github.com/istio/istio/issues/22124); [HTTP/1.1 service returning 503 upstream connect error for multipart uploads · Issue #27423](https://github.com/istio/istio/issues/27423) (protocol-name mismatch causing broken upstream connections).

## client-wrong-namespace-qualified-name

- **Mechanism**: A `loadgen` rollout (or a copy-paste from a staging
  manifest) fully-qualifies its target as
  `payments.<wrong-namespace>.svc.cluster.local` instead of the short name
  `payments`, which would have resolved correctly inside `loadgen`'s own
  `demo` namespace via the DNS search path. If a same-named `payments`
  Service genuinely exists in that other namespace (a common case: staging
  and prod namespaces both run a service called `payments`), the request
  **succeeds** - against the wrong backend. This is the sharpest departure
  from `client-dns-typo`: there is no NXDOMAIN, no connection error, no log
  line at all. Traffic to the real `payments` in `demo` vanishes while the
  caller reports 200 OK the entire time.
- **Telemetry signature**: absence of traffic to `payments.demo` - same
  shape as the other three wrong-target variants - but *not* absence of
  traffic overall: a query scoped to the wrong namespace shows the caller's
  full request volume landing there instead. This is corroborating mesh
  evidence the other variants don't have, if the dossier is willing to drop
  its namespace scope and search laterally.
- **Signal draft (PromQL)**: primary (fires the incident, same as above):
  `((sum(rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments", destination_service_namespace="demo"}[2m])) or vector(0)) < bool 0.05) * (max_over_time(...)[30m:1m] > bool 0.5)`.
  Corroborating (namespace-unscoped, would need to be added as new
  evidence): `sum by (destination_service_namespace) (rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments"}[5m]))`  - 
  shows a namespace other than `demo` receiving what should have been
  `demo`'s traffic.
- **Inject sketch**:
  ```
  kubectl create namespace demo-shadow
  kubectl label namespace demo-shadow istio.io/dataplane-mode=ambient
  kubectl -n demo-shadow apply -f - <<'EOF'
  # a decoy payments-shaped fake-service + Service, same name, wrong namespace
  EOF
  kubectl -n demo patch deploy/loadgen --type=json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/args",
       "value":["while true; do curl -s -o /dev/null http://payments.demo-shadow.svc.cluster.local:9090/; sleep 0.2; done"]}]'
  kubectl -n demo rollout status deploy/loadgen --timeout=60s
  ```
- **Triage signatures**: none in logs - this is the point. The rollout diff
  on `loadgen` is the only definitive signal: `spec.template.spec.containers[0].args`
  shows a namespace suffix (`.demo-shadow.svc.cluster.local`) that does not
  match `loadgen`'s own namespace. No existing log pattern fires because
  nothing errors.
- **Detectable deterministically?**: partial - the primary absence signal
  and rollout diff are enough to *raise* the incident and *name* the
  changed line, but confirming the traffic actually landed on a decoy
  (rather than just vanishing) needs the namespace-unscoped evidence query,
  which the current triage layer does not run.
- **Overlaps existing catalog?**: extends `traffic-vanished-triage`, but
  exposes a framing gap in it: the entry's own description assumes the
  root cause is "a dead upstream caller" or "a broken hostname" - i.e. that
  wherever the traffic went, it went nowhere. This variant shows traffic can
  vanish from the watched service while going somewhere very real. Worth a
  one-line addition to that entry's description once validated.
- **Sources**: [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) (unqualified names resolve within the pod's own namespace search path); [DNS doesn't work properly from different namespaces · Issue #14533](https://github.com/kubernetes/kubernetes/issues/14533); [How to Fix GKE Pod-to-Service Communication Failures Across Namespaces](https://oneuptime.com/blog/post/2026-02-17-how-to-fix-gke-pod-to-service-communication-failures-across-namespaces/view).

## networkpolicy-new-deny

- **Mechanism**: A `NetworkPolicy` is newly applied in `demo` (e.g. a
  default-deny ingress policy added for a compliance sweep, or a policy
  scoped to `loadgen`'s labels that omits an egress rule to `payments`).
  Traffic from `loadgen` to `payments` is dropped by the CNI before it ever
  reaches ztunnel. **Testbed caveat**: `payments.yaml`'s testbed runs on
  kind, whose default CNI is kindnet, which does not implement
  NetworkPolicy enforcement at all - applying this object on the current
  testbed is a no-op and the fault will not reproduce. Validating this
  candidate for real requires swapping in Calico or Cilium as the kind
  cluster's CNI first.
- **Telemetry signature**: absence of traffic, same shape as the DNS-typo
  family, if enforced. On an enforcing CNI, blocked packets typically time
  out rather than RST, so the client sees a connect timeout, not a refused
  connection.
- **Signal draft (PromQL)**: same absence-of-traffic query as above, scoped
  to `payments`/`demo` - unchanged from `traffic-vanished-triage.yaml`.
- **Inject sketch** (requires an enforcing CNI, not this kind default):
  ```
  kubectl -n demo apply -f - <<'EOF'
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: block-loadgen-egress
    namespace: demo
  spec:
    podSelector:
      matchLabels:
        app: loadgen
    policyTypes: ["Egress"]
    egress: []
  EOF
  ```
- **Triage signatures**: log sweep on `loadgen` shows connect timeouts  - 
  regex `i/o timeout` or `connection timed out`, both **already** in
  `traffic-vanished-triage`'s pattern list. Object evidence needed but not
  yet in the dossier: `kubectl -n demo get networkpolicy -o yaml` and its
  `creationTimestamp`, cross-referenced against the incident start time  - 
  the rollout-diff evidence only watches Deployments today, not
  NetworkPolicy objects.
- **Detectable deterministically?**: partial - the log regex is already
  covered, but the causal pin (a *NetworkPolicy* rather than a dead
  upstream) needs a new object-evidence type (list NetworkPolicies in the
  namespace, sorted by age) that the triage layer does not currently run.
  On this specific testbed, also flatly "no" until the CNI is swapped.
- **Overlaps existing catalog?**: new - closest relative is
  `traffic-vanished-triage` (same absence signal, two already-covered log
  patterns), extended with a NetworkPolicy-object evidence type it lacks.
- **Sources**: NetworkPolicy blocking traffic, a common real class (note that
  even k3s's built-in NP controller and Calico's felix can fail to enforce under
  some kernels - the same "does it even enforce here" question this candidate's
  caveat raises); [Kind CNI Does Not Support Default Deny Network Policy · Issue #3705](https://github.com/kubernetes-sigs/kind/issues/3705); [NetworkPolicy support · Issue #842, kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind/issues/842).

## dependency-down-cascading-errors

- **Mechanism**: `payments` calls a downstream dependency (DB, or another
  API) that goes down. Unlike every other candidate in this file, the
  *watched service's own* mesh telemetry does react: `payments` starts
  answering its callers with 5xx because its own backend call fails. The
  danger is not invisibility, it's misattribution: this produces the exact
  same signal `error-surge-outlier-ejection` alerts on, and that catalog
  entry's own rollback note already warns about this ("if the 5xx ratio
  does not drop after ejection, the failure is uniform across endpoints  - 
  bad deploy, downstream dependency - and this patch is not the fix").
  Ejecting `payments` endpoints does nothing when the actual failure is one
  hop further out.
- **Telemetry signature**: real signal - 5xx ratio on `payments` rises,
  uniformly across all its endpoints/subsets (not concentrated on one bad
  pod, which is the tell that outlier ejection is the wrong lever).
- **Signal draft (PromQL)**: reuses `error-surge-outlier-ejection.yaml`'s
  signal verbatim:
  `sum(rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments", destination_service_namespace="demo", response_code=~"5.."}[2m])) / sum(rate(istio_requests_total{reporter=~"destination|waypoint", destination_service_name="payments", destination_service_namespace="demo"}[2m])) > 0.15`
- **Inject sketch**: `fake-service` (the image already used for
  `payments-v1`/`v2`) natively supports chaining to an `UPSTREAM_URIS`
  dependency, so the testbed can add a real one:
  ```
  # add a payments-db fake-service + Service to demo (once), then:
  kubectl -n demo set env deploy/payments-v2 UPSTREAM_URIS=http://payments-db:9091
  kubectl -n demo rollout status deploy/payments-v2 --timeout=60s
  # then take the dependency down:
  kubectl -n demo scale deploy/payments-db --replicas=0
  ```
- **Triage signatures**: log sweep on `payments-v2` (not on a caller this
  time - the dependency call is outbound from the workload itself) shows
  `connection refused` or `i/o timeout` against the dependency's host  - 
  already-covered regexes, but the sweep target is wrong: `traffic-vanished-triage`'s
  `logEvidence` is scoped to the *namespace*, which would catch this by
  accident, but nothing currently distinguishes "payments failing because
  of its own bug" from "payments failing because payments-db is down"
  except which workload's logs the pattern matched in.
- **Detectable deterministically?**: partial - the alerting signal fires
  correctly (it's a real error surge), but root-cause attribution to an
  external dependency versus an internal regression needs log evidence
  naming the dependency host, which today's `evidence` block for
  `error-surge-outlier-ejection` doesn't collect (it collects
  `destination_workload` breakdowns of the *same* service, not its callees).
- **Overlaps existing catalog?**: extends `error-surge-outlier-ejection`
  directly; the risk is that catalog entry auto-applies outlier detection
  and reports success when the errors don't drop, exactly as its own
  rollback text anticipates.
- **Sources**: dependency-down cascading errors, a common real class;
  [Postmortem: Database Connection Pool Exhaustion Causing Service Outage](https://medium.com/@ngungabn03/postmortem-database-connection-pool-exhaustion-causing-service-outage-9afd33a45311); `catalog/error-surge-outlier-ejection.yaml` (rollback note already names this exact failure mode).

## configmap-secret-startup-break

- **Mechanism**: A rollout adds or edits a `ConfigMap`/`Secret` reference on
  `payments-v2` (`envFrom`, `env[].valueFrom`, or a mounted volume) that
  points at an object that doesn't exist, or exists but is missing an
  expected key. The kubelet cannot construct the container at all - this
  never becomes a running process that could crash, it's a
  `CreateContainerConfigError` at the pod-status level. No mesh signal is
  possible because no request is ever accepted; the pod never reaches
  `Running`, let alone `Ready`.
- **Telemetry signature**: no mesh signal. If the whole `payments-v2`
  replica set fails this way, `payments` traffic thins (v1 still serves,
  v2's 20% weight starts erroring UH/503 at the subset). If both subsets
  broke this way, traffic to `payments` would vanish entirely - same
  absence shape as the DNS-typo family, but with an entirely different
  object-status root cause.
- **Signal draft (PromQL)**: n/a - object/log evidence only. (A
  `kube_deployment_status_replicas_available` gauge would be the natural
  corroborating query if kube-state-metrics is scraped on this testbed;
  not confirmed present, so not asserted here.)
- **Inject sketch**:
  ```
  kubectl -n demo patch deploy/payments-v2 --type=json -p \
    '[{"op":"add","path":"/spec/template/spec/containers/0/envFrom",
       "value":[{"configMapRef":{"name":"payments-v2-config-typo"}}]}]'
  kubectl -n demo rollout status deploy/payments-v2 --timeout=60s   # will not reach success
  ```
- **Triage signatures**: `kubectl -n demo get pods` shows status
  `CreateContainerConfigError`; `kubectl -n demo describe pod <payments-v2-...>`
  events show `Error: configmap "payments-v2-config-typo" not found`. Log
  regex is not applicable (no container log stream exists yet); this is
  purely object/event evidence - pod `status.containerStatuses[].state.waiting.reason`
  and the Warning event reason `Failed`. Rollout diff on `payments-v2` shows
  the new `envFrom` block appear.
- **Detectable deterministically?**: yes - `CreateContainerConfigError` is
  an exact, unambiguous pod-status field, and the missing-object name is in
  the event message verbatim.
- **Overlaps existing catalog?**: new - none of the 9 current entries
  collect pod/container status fields or events; the rollout-diff evidence
  only diffs the Deployment template, which would show the change but not
  confirm it broke startup. Needs a "pod status + events" evidence type.
- **Sources**: [Troubleshoot CrashLoopBackOff events, Google Kubernetes Engine docs](https://cloud.google.com/kubernetes-engine/docs/troubleshooting/crashloopbackoff-events) (`CreateContainerConfigError` as the distinct status for missing ConfigMap/Secret references, versus CrashLoopBackOff for a container that starts and then exits); [How to Fix CrashLoopBackOff in Kubernetes? - Komodor](https://komodor.com/learn/how-to-fix-crashloopbackoff-kubernetes-error/).

## image-tag-bad-rollout

- **Mechanism**: A rollout bumps `payments-v2`'s image tag to one that
  doesn't exist (typo'd version, or a build that was never pushed) or to a
  real tag whose binary crashes immediately on start (a broken build that
  passed CI but fails at runtime). The first case never starts a container
  (`ImagePullBackOff`/`ErrImagePull`); the second starts and exits
  repeatedly (`CrashLoopBackOff`, distinct exit code). Either way
  `payments-v2` contributes zero healthy endpoints to its subset.
- **Telemetry signature**: the `payments` VirtualService still sends 20%
  of weight to the `v2` subset, which now has no healthy endpoints, so that
  slice of traffic gets Envoy's "no healthy upstream" (UH) response flag  - 
  the same signal `upstream-host-ejection-flood` already watches for.
  `payments` overall does not go silent (v1 keeps serving 80%); this is a
  partial, subset-scoped version of the absence pattern.
- **Signal draft (PromQL)**: reusing `upstream-host-ejection-flood`'s shape
  (not quoted verbatim here since its exact promql wasn't reviewed in
  detail for this candidate) - conceptually
  `sum(rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo", destination_version="v2", response_flags=~".*UH.*"}[2m])) > 0`.
- **Inject sketch**:
  ```
  kubectl -n demo set image deploy/payments-v2 payments=nicholasjackson/fake-service:vtypo-does-not-exist
  kubectl -n demo rollout status deploy/payments-v2 --timeout=60s   # will not reach success
  ```
- **Triage signatures**: `kubectl -n demo get pods` shows
  `ImagePullBackOff`/`ErrImagePull` (bad tag) or `CrashLoopBackOff` with a
  non-zero, non-137 exit code (broken build). Rollout diff on
  `payments-v2` shows the exact `image:` line change - the single most
  actionable line in the whole dossier, since `kubectl rollout undo` is the
  entire fix.
- **Detectable deterministically?**: yes - both container-status reasons
  are exact, and the rollout diff pins the changed tag precisely.
- **Overlaps existing catalog?**: extends `upstream-host-ejection-flood`
  (same UH signal), but that entry's remediation - relax the outlier
  ejection ceiling - is actively wrong here: the subset isn't ejected by an
  outlier policy, it's genuinely never up. Needs the same container-status
  evidence type as `configmap-secret-startup-break` to distinguish
  "policy ejected it" from "it was never healthy."
- **Sources**: [10 Most Common Reasons Kubernetes Deployments Fail (Part 1)](https://kukulinski.com/10-most-common-reasons-kubernetes-deployments-fail-part-1/); [What Is Kubernetes ImagePullBackOff Error and How to Fix It - Dash0](https://www.dash0.com/guides/kubernetes-imagepullbackoff); `catalog/upstream-host-ejection-flood.yaml` (UH signal this shares and the wrong-remedy risk).

## readiness-probe-misconfig

- **Mechanism**: A rollout adds or edits `payments-v2`'s `readinessProbe`
  to point at the wrong port or path (`payments-v1`/`v2` currently define
  no probes at all, so this candidate is specifically about *introducing*
  a broken one). The container starts and stays `Running` - the
  application itself is fine - but the probe always fails, so the kubelet
  never marks it `Ready` and the endpoint controller removes it from the
  `payments` Service's Endpoints. Ambient-mode caveat: Istio's known
  probe-rewrite hazard (pilot-agent rewriting probes through port 15020,
  which can strand a pod if the sidecar isn't ready first) is a
  **sidecar-injection-specific** mechanism and does not apply to this
  testbed - ambient has no per-pod sidecar to rewrite through. This
  candidate is a plain Kubernetes probe misconfiguration, not a mesh one.
- **Telemetry signature**: same subset-scoped UH pattern as
  `image-tag-bad-rollout` - `payments-v2` has zero Ready endpoints, so its
  slice of VirtualService weight gets no healthy upstream.
- **Signal draft (PromQL)**: same conceptual query as
  `image-tag-bad-rollout`: `sum(rate(istio_requests_total{destination_service_name="payments", destination_service_namespace="demo", destination_version="v2", response_flags=~".*UH.*"}[2m])) > 0`.
- **Inject sketch**:
  ```
  kubectl -n demo patch deploy/payments-v2 --type=json -p \
    '[{"op":"add","path":"/spec/template/spec/containers/0/readinessProbe",
       "value":{"httpGet":{"path":"/healthz-typo","port":9091},"periodSeconds":5,"failureThreshold":1}}]'
  kubectl -n demo rollout status deploy/payments-v2 --timeout=60s   # will not reach success
  ```
- **Triage signatures**: `kubectl -n demo get pods` shows the pod
  `Running` but `0/1 Ready`; `kubectl -n demo get endpoints payments`
  shows one fewer address than expected; `kubectl -n demo describe pod`
  events show `Readiness probe failed: Get "http://...:9091/healthz-typo":
  dial tcp ...: connect: connection refused` (or a 404, depending on the
  wrong path/port chosen). Rollout diff shows the new `readinessProbe`
  block. No application log line is wrong at all - the app is healthy.
- **Detectable deterministically?**: yes - `Running` + not-`Ready` +
  a probe-failure event with the specific path/port is an exact,
  unambiguous object/event signature.
- **Overlaps existing catalog?**: extends `upstream-host-ejection-flood`
  the same way `image-tag-bad-rollout` does (shared UH signal, same
  wrong-remedy risk from relaxing ejection instead of fixing the probe).
  Needs a "Ready condition + probe-failure event" evidence type, which
  also covers the OOM candidate below.
- **Sources**: [Kubernetes: Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/); [Istio / Health Checking of Istio Services](https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/) (documents the sidecar-mode probe-rewrite mechanism this candidate is explicitly distinguished from); [Readiness probe failed when auto injected a sidecar and opened mtls STRICT mode · Issue #41010](https://github.com/istio/istio/issues/41010).

## oom-kill-resource-limit

- **Mechanism**: A rollout lowers `payments-v2`'s memory limit below its
  actual steady-state working set (copy-pasted from a smaller service, or
  an over-aggressive bin-packing pass). The kernel OOM-killer kills the
  container when it crosses the cgroup limit; kubelet reports
  `OOMKilled`, exit code 137, and restarts it, which immediately OOMs again
  under the same limit - a distinct flavor of crash-looping from a bad
  image or bad config, identifiable purely by the terminated-reason field.
- **Telemetry signature**: intermittent - the pod cycles between briefly
  `Ready` (right after restart) and gone from Endpoints (mid-OOM-crash), so
  `payments-v2`'s slice of traffic shows flapping UH/503 bursts correlated
  with restart timestamps, rather than the clean, permanent zero of the
  other subset-down candidates.
- **Signal draft (PromQL)**: n/a as a clean threshold - a flapping signal
  needs a rate-of-restarts or variance detector, not a level threshold; the
  cleanest deterministic query is over the object field, not Prometheus:
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`
  if kube-state-metrics is present (not confirmed on this testbed).
- **Inject sketch**:
  ```
  # verify current RSS first (kubectl top pod), then set a limit below it:
  kubectl -n demo patch deploy/payments-v2 --type=json -p \
    '[{"op":"add","path":"/spec/template/spec/containers/0/resources",
       "value":{"limits":{"memory":"8Mi"},"requests":{"memory":"8Mi"}}}]'
  kubectl -n demo rollout status deploy/payments-v2 --timeout=60s
  ```
- **Triage signatures**: `kubectl -n demo get pod <payments-v2-...> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'`
  returns `OOMKilled`; exit code `137` in the same terminated block;
  `restartCount` climbing. Rollout diff on `payments-v2` shows the lowered
  `resources.limits.memory` line - the single actionable fix (raise it back
  or profile actual usage). No log regex applies; the application never
  gets to log anything before SIGKILL.
- **Detectable deterministically?**: yes - `OOMKilled` + exit code 137 is
  as unambiguous as object evidence gets.
- **Overlaps existing catalog?**: new - same missing evidence type as
  `readiness-probe-misconfig` and `configmap-secret-startup-break`
  (container/pod status fields), plus it needs a flap/restart-rate
  detector none of the 9 current PromQL-threshold entries implement.
- **Sources**: [How to Fix OOMKilled Kubernetes Error (Exit Code 137)? - Komodor](https://komodor.com/learn/how-to-fix-oomkilled-exit-code-137/); [Exit Code 137 - Fixing OOMKilled Kubernetes Error - Spacelift](https://spacelift.io/blog/oomkilled-exit-code-137).
