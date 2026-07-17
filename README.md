# mesh-incidents-bench

Reproducible service mesh failure scenarios, with ground truth, for scoring
how well diagnostic and remediation tools handle mesh-layer incidents.

Plenty of tools claim to troubleshoot Kubernetes. Almost none of them speak
the mesh's language: traffic splits, outlier ejection, connection pools,
mTLS modes. This benchmark makes that measurable. Every scenario is a real
fault injected into a real Istio ambient mesh, with a documented root cause
and the remediation an experienced mesh operator would apply.

## Scenarios (v0.1)

| id | fault | mesh-native remediation |
| --- | --- | --- |
| `canary-latency` | canary subset p99 regression | shift traffic back to stable |
| `error-surge` | one subset throwing 5xx | outlier ejection or rollback |
| `pool-overflow` | circuit breaker shedding load (UO) | right-size the connection pool |
| `mtls-conflict` | plaintext client vs STRICT mTLS | enroll client or scoped PERMISSIVE |

Each scenario directory contains `inject.sh`, `check.sh` (exits 0 while the
incident is live), `reset.sh`, and `ground-truth.md` with the root cause,
the expected remediation, and the scoring rubric.

## Scoring

Three questions per scenario, 0 to 2 points each:

1. **Detection**: did the tool notice something is wrong with the workload?
2. **Diagnosis**: did it name the actual root cause?
3. **Remediation**: did it propose the mesh-native fix an operator would take?

Scores are assigned by a human against the rubric in each `ground-truth.md`.
Runs are honest: misses are published, including the benchmark author's own
tool. See `results/`.

## Leaderboard (v0.1, 2026-07-17)

| tool | canary-latency | error-surge | pool-overflow | mtls-conflict | total /24 |
| --- | --- | --- | --- | --- | --- |
| [MeshMedic](https://github.com/kassvl/meshmedic) * | 6 | 5 | 6 | 0 | **17** |
| k8sgpt (no AI backend) | 0 | 0 | 0 | 0 | **0** |
| HolmesGPT | not run yet (needs an LLM key); PRs welcome | | | | |

\* Same author as this benchmark, and the scenarios overlap MeshMedic's
catalog: a home game, disclosed as such in [results/meshmedic.md](results/meshmedic.md).
The k8sgpt zero is not a k8sgpt bug: its analyzers inspect object state and
every mesh incident here leaves the objects healthy. That gap is the point
of the benchmark; details in [results/k8sgpt.md](results/k8sgpt.md).
Everyone misses `mtls-conflict` in ambient mode so far, the author's tool
included: the rejection happens at L4, below the request metrics.

## Testbed

Scenarios run against the [MeshMedic demo environment](https://github.com/kassvl/meshmedic)
(kind + Istio ambient + a two-version payments service + Prometheus): bring
it up with `demo/scripts/00..02`, then:

```console
$ ./harness/run.sh scenarios/canary-latency 300 -- <your tool command>
```

The harness injects the fault, waits until `check.sh` confirms the incident
is observable, runs your tool with the incident live, saves its output under
`results/raw/`, and resets the testbed.

## License

Apache-2.0
