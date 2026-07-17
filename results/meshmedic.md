# MeshMedic results

- Tool: [MeshMedic](https://github.com/kassvl/meshmedic), report-only mode
  (`meshmedic watch`, full catalog, no gitops)
- Date: 2026-07-17, testbed: kind + Istio 1.24 ambient, single node
- Raw output: `raw/*-meshmedic-*.txt`

**Disclosure**: this benchmark and MeshMedic share an author, and the
scenarios overlap MeshMedic's remediation catalog. Treat MeshMedic's numbers
as a home game. The rubric misses below are published unedited; outside
scenario contributions are the fix for the bias and are welcome.

| scenario | detection | diagnosis | remediation | total |
| --- | --- | --- | --- | --- |
| canary-latency | 2 | 2 | 2 | 6 |
| error-surge | 2 | 1 | 2 | 5 |
| pool-overflow | 2 | 2 | 2 | 6 |
| mtls-conflict | 0 | 0 | 0 | 0 |
| **total** | | | | **17 / 24** |

## Notes per scenario

- **canary-latency**: fired `canary-latency-rollback` after the 90s hold
  (signal 2477ms vs 1000ms threshold), named subset `v2`, proposed the
  VirtualService shift to stable. Full marks.
- **error-surge**: fired `error-surge-outlier-ejection` (ratio 0.194 vs
  0.15) with the DestinationRule outlier patch. Diagnosis scored 1, not 2:
  the `errors-by-pod` evidence query reduces to a single number and drops
  the pod label, so the report never actually says the 500s come from the
  `v2` subset. Known gap, found by this run: evidence results need labels.
- **pool-overflow**: fired `connection-pool-overflow` (UO at 13.1 rps),
  named the pool limit, proposed the DestinationRule resize. Also fired
  `error-surge-outlier-ejection`, which is technically true (UO responses
  are 503s) but is a cascade symptom, not a second incident. Both evidence
  queries returned no data on the testbed: `container_cpu_*` needs cadvisor
  scraping and `envoy_cluster_*` needs the stats inclusion annotation,
  neither of which the Istio Prometheus addon provides.
- **mtls-conflict**: complete miss, as predicted in the scenario's ground
  truth. In ambient mode ztunnel rejects the plaintext client at L4 and
  nothing reaches the L7 request metrics MeshMedic watches. Fixing this
  needs an L4 signal source (ztunnel telemetry), not a better threshold.
  A first attempt at this run (kept as `*-STALE-SIGNAL.txt`) had MeshMedic
  firing `connection-pool-overflow` on the decaying UO tail of the previous
  scenario; that run was invalidated, the harness gained a mandatory
  quiesce period between scenarios, and the run was repeated cleanly.
