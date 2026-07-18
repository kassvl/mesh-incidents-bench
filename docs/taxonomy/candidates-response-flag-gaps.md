# Candidates: response-flag coverage gaps

High-value flags from `response-flags-coverage.md` not yet covered, written to
the `TEMPLATE.md` shape, grounded on the real payments testbed (VirtualService
`payments`: one catch-all http route, 80/20 v1/v2; DestinationRule `payments`:
subsets v1/v2; ambient with an L7 waypoint). Detailed here; each still validated
step by step before any catalog entry.

## no-route-blackhole

- **Mechanism**: a VirtualService route is narrowed to a match condition the
  live traffic does not satisfy (a header, a URI prefix) with no catch-all
  fallback, so matching requests find no route and the proxy returns 404 with
  the `NR` flag while the backend is healthy and idle. A common real outcome of
  a bad routing edit.
- **Telemetry signature (VALIDATED 2026-07-18)**: `istio_requests_total{
  reporter="waypoint", response_code="404", response_flags="NR"}` rising, but
  attributed to the **source**, not the destination: a no-route request never
  resolves a destination, so it is stamped `destination_service_name="unknown"`,
  `destination_workload="unknown"`, and only `source_workload` /
  `source_workload_namespace` identify it. Live capture: `reporter=waypoint
  code=404 flags=NR source_workload=loadgen dst_svc=unknown rate=3.878`. This is
  the gotcha: a destination-keyed query (like every other catalog entry) sees
  nothing. NR is the first source-keyed class.
- **Signal draft (PromQL, corrected after validation)**:
  `sum(rate(istio_requests_total{reporter="waypoint",
  source_workload_namespace="{{.namespace}}", response_flags="NR"}[2m])) > 0.5`
- **Inject sketch**: patch the `payments` VirtualService so its only route
  requires a header loadgen never sends, leaving no default:
  `kubectl -n demo patch virtualservice payments --type=json -p '[{"op":"add","path":"/spec/http/0/match","value":[{"headers":{"x-route-key":{"exact":"canary-only"}}}]}]'`.
  Reset by removing the match. loadgen's plain requests then miss the route.
- **Triage signatures**: object evidence on the VirtualService (`spec.http[*].match`,
  `spec.http[*].route`) puts the over-narrow match next to the 404 symptom. No
  new log signature needed.
- **Detectable deterministically?**: yes, expected. NR is a standard flag and
  the inject is a clean config edit. Confirm the flag and reporter live.
- **Overlaps existing catalog?**: new. Distinct from route-timeout (UT) and from
  ejection (UH): here the route itself is missing, not the backend.
- **Sources**: Envoy RESPONSE_FLAGS (`NR` = no route configured); Istio traffic
  management docs on VirtualService match/route ordering.

## dns-resolution-failure-mesh

- **Mechanism**: a ServiceEntry (or external destination) resolves by DNS and
  the name does not resolve, so the proxy cannot open the upstream connection
  and stamps `DF`. This is the mesh-native counterpart to the client-side
  `client-dns-typo` (which is a curl error in loadgen logs, caught by triage).
- **Telemetry signature**: candidate `istio_requests_total{response_flags="DF"}`
  or a connection-failure flag on the ServiceEntry host. **Uncertain in ambient**:
  in-mesh service-to-service uses EDS, not DNS, and whether ztunnel/waypoint
  surfaces `DF` on `istio_requests_total` for a failed ServiceEntry lookup is
  not confirmed. Do not claim a signal until observed.
- **Signal draft (PromQL)**: n/a until the flag is confirmed live; if it does
  not surface, this class stays covered by the client-side triage instead.
- **Inject sketch**: create a ServiceEntry with `resolution: DNS` for a host
  like `nonexistent.invalid`, route loadgen at it, observe whether any mesh
  flag appears versus only a client-side log line.
- **Triage signatures**: resolver failure lines in loadgen/proxy logs, same
  family as `client-dns-typo`.
- **Detectable deterministically?**: partial/uncertain. The client-side path is
  already covered; the mesh-native `DF` signal needs live confirmation and may
  not exist in ambient. Honest open question.
- **Overlaps existing catalog?**: extends `client-dns-typo` / traffic-vanished
  triage. Only becomes a new entry if a distinct mesh signal is confirmed.
- **Sources**: Envoy RESPONSE_FLAGS (`DF` = DNS resolution failed); HolmesGPT
  fixtures `42_dns_issues_*` (their own DNS-failure test family).

## upstream-connection-failure-family

- **Mechanism**: the backend refuses, resets, or terminates the connection
  mid-request (crash under load, wrong listener, abrupt close), so the proxy
  reports `UF` (connection failure), `UR` (remote reset), or `UC` (connection
  termination) rather than a clean 5xx.
- **Telemetry signature**: `istio_requests_total{response_flags=~"UF|UR|UC"}`
  from the waypoint reporter for `payments`.
- **Signal draft (PromQL)**: `sum(rate(istio_requests_total{reporter="waypoint",
  destination_service_name="payments", destination_service_namespace="demo",
  response_flags=~"UF|UR|UC"}[2m])) > 0.5`
- **Inject sketch**: make payments-v2 close connections abruptly under traffic
  (app-level abrupt close, or a listener on the wrong port so the waypoint's
  upstream connect fails). Which exact flag appears depends on timing; capture
  it rather than assuming.
- **Triage signatures**: rollout diff on payments-v2 (a bad image/port change),
  connection-reset log lines.
- **Detectable deterministically?**: partial. The flag family is real, but which
  code appears and how cleanly it separates from UH needs live experimentation.
- **Overlaps existing catalog?**: adjacent to `upstream-host-ejection-flood`
  (UH) but distinct: UH is no healthy endpoint, UF/UR/UC is a per-connection
  failure to a present endpoint.
- **Sources**: Envoy RESPONSE_FLAGS (`UF`/`UR`/`UC`); Istio issues on backend
  connection resets surfacing as 503 UC.
