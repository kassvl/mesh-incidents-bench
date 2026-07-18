# MeshMedic results

- Tool: [MeshMedic](https://github.com/kassvl/meshmedic), report-only mode
  (`meshmedic watch`, full catalog, no gitops)
- Date: 2026-07-17 (v0.2 rerun, post M2.5 changes), testbed: kind + Istio
  1.24 ambient, single node
- Raw output: `raw/*-meshmedic-*.txt` (v0.2 runs are the 22:25+ timestamps)

**Disclosure**: this benchmark and MeshMedic share an author, and the
scenarios overlap MeshMedic's remediation catalog. More than that: the v0.2
MeshMedic changes were developed against these exact scenarios, including
the ztunnel L4 signal that fixed `mtls-conflict`. Treat these numbers as a
home game played after studying the tape. The scoring rubric is public,
the raw outputs are unedited, and outside scenario contributions remain
the honest fix for the bias.

| scenario | detection | diagnosis | remediation | total |
| --- | --- | --- | --- | --- |
| canary-latency | 2 | 2 | 2 | 6 |
| error-surge | 2 | 2 | 2 | 6 |
| pool-overflow | 2 | 2 | 2 | 6 |
| mtls-conflict | 2 | 2 | 2 | 6 |
| noise-only | 2 | 2 | 2 | 6 |
| client-dns-typo (v0.3 triage) | 2 | 2 | 2 | 6 |
| **total** | | | | **36 / 36** |

Harness-measured, per run: tool wall time 120-210s (bounded by the watch
window given to it, detection itself lands on the first 15s tick after the
signal's hold duration), and **0 cluster objects created or deleted** in
every run.

## Notes per scenario

- **canary-latency**: fired `canary-latency-rollback` (p99 2482ms vs
  1000ms), proposed the VirtualService shift to stable. New in v0.2: the
  report's configuration evidence reads the canary Deployment and shows
  `TIMING_50_PERCENTILE=1200ms` — the injected root cause — next to the
  stable subset's 48ms comparison. That config-level depth was previously
  HolmesGPT's unique advantage, found by a nine-minute LLM investigation;
  it is now a deterministic kubectl read.
- **error-surge**: fired `error-surge-outlier-ejection` (ratio 0.218 vs
  0.15). The v0.1 gap is closed: evidence queries keep their labels, so the
  report shows `errors-by-workload{destination_workload="payments-v2"}` at
  0.93 rps with v1 absent from the error rows — the 500s are named to the
  v2 subset, and the configuration evidence shows `ERROR_RATE=0.9
  ERROR_CODE=500` on that Deployment. Diagnosis 1 → 2.
- **pool-overflow**: fired `connection-pool-overflow` (13.65 UO rps) once.
  The v0.1 cascade double-fire is gone: the raw log shows
  `error-surge-outlier-ejection: suppressed by connection-pool-overflow:
  cascade symptom, not a second incident`. Both v0.1 evidence queries that
  needed unavailable scrape targets were replaced with mesh-native ones,
  which now return data; configured resources come from object evidence
  (`replicas: 1`, no limits) to make the raise-vs-scale call reviewable.
- **mtls-conflict**: the scenario every tool missed in v0.1, MeshMedic
  included, is now detected at full marks. The new
  `mtls-policy-conflict-ambient` entry watches ztunnel's L4 telemetry:
  `istio_tcp_connections_closed_total{response_flags="DENY"}`. The report
  names the denied client (`plain-client`, `source_principal="unknown"` —
  no mesh identity), lists the namespace's PeerAuthentication policies
  (`demo-strict`, mode STRICT) as configuration evidence, and proposes the
  scoped PERMISSIVE fallback with an enroll-the-client rollback. The
  ground-truth note said the signal existed in ztunnel; it does, and it is
  already in the stock Prometheus addon's scrape.
- **noise-only** (new in v0.2): with an empty ConfigMap, an endpoint-less
  Service and a completed one-off pod in the namespace and the service
  healthy, MeshMedic emitted nothing for the whole window. On this
  scenario's inverted rubric, silence is the correct answer: thresholds
  with hold durations do not chase noise.
- **client-dns-typo** (v0.3 triage layer): the breadth-honesty control,
  where MeshMedic first scored 0 as designed. The v0.3 triage layer now
  fires `traffic-vanished-triage`: an absence signal (`or vector(0)` plus
  a `max_over_time` 30m baseline) confirms traffic that flowed is now
  gone, then the dossier attaches the log-signature sweep (loadgen's
  `Could not resolve host: payments-svc.demo` from its own logs) and the
  rollout diff (`- http://payments:9090/` → `+ http://payments-svc.demo:9090/`,
  the bad line verbatim). No patch is proposed (report-only); the dossier
  is the deliverable. Live verification of this layer caught two real
  bugs now regression-tested: Kubernetes reuses an existing ReplicaSet on
  rollback so ReplicaSet age lies about rollout time (fixed by reading the
  Deployment's Progressing lastUpdateTime), and a fixed-offset baseline
  goes blind inside back-to-back outages (fixed with max_over_time). A
  regression run confirmed the triage scenario does not false-fire on
  error-surge.
