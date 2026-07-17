# mesh-incidents-bench

Reproducible service mesh failure scenarios, with ground truth, for scoring
how well diagnostic and remediation tools handle mesh-layer incidents.

Plenty of tools claim to troubleshoot Kubernetes. Almost none of them speak
the mesh's language: traffic splits, outlier ejection, connection pools,
mTLS modes. This benchmark makes that measurable. Every scenario is a real
fault injected into a real Istio ambient mesh, with a documented root cause
and the remediation an experienced mesh operator would apply.

## Scenarios (v0.2)

| id | fault | mesh-native remediation |
| --- | --- | --- |
| `canary-latency` | canary subset p99 regression | shift traffic back to stable |
| `error-surge` | one subset throwing 5xx | outlier ejection or rollback |
| `pool-overflow` | circuit breaker shedding load (UO) | right-size the connection pool |
| `mtls-conflict` | plaintext client vs STRICT mTLS | enroll client or scoped PERMISSIVE |
| `noise-only` | none: healthy service plus harmless noise | none; silence is the correct answer |
| `client-dns-typo` | client targets a non-resolving host, payments traffic drops to zero | none in the mesh; fix the client's target host |

`noise-only` inverts the detection axis: it measures false-positive
discipline, the alert-fatigue failure mode the fault scenarios cannot see.

`client-dns-typo` is the breadth-honesty control. Every fault scenario above
emits a pathological mesh signal that a catalog of threshold detectors can
match; this one is a real, total outage (100% of user-facing calls fail) that
shows up only as the *absence* of telemetry, one layer above the mesh in a
client's own config. Catalog-based tools, MeshMedic included, are expected to
score 0 here by design — no query fires on traffic that has stopped — while an
agentic investigator that reads the client's logs and Deployment spec can
root-cause it. It keeps the leaderboard honest about what a mesh-native
detector structurally cannot see.

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

## Leaderboard (v0.2, 2026-07-17)

| tool | canary-latency | error-surge | pool-overflow | mtls-conflict | noise-only | total |
| --- | --- | --- | --- | --- | --- | --- |
| [MeshMedic](https://github.com/kassvl/meshmedic) * | 6 | 6 | 6 | 6 | 6 | **30 / 30** |
| HolmesGPT (mistral-large) † | 6 | 5 | 0 | 0 | 3 | **14 / 30** |
| k8sgpt (no AI) | 0 | 0 | 0 | 0 | 4 | **4 / 30** |
| k8sgpt (AI, mistral-large) | 0 | 0 | 0 | 0 | 2 | **2 / 30** |

\* Same author as this benchmark, and the v0.2 MeshMedic changes were
developed against these exact scenarios: a home game played after studying
the tape, disclosed in full in [results/meshmedic.md](results/meshmedic.md).
Outside scenarios and reruns of the other tools are welcome as PRs.

† canary-latency and error-surge carry over from v0.1 (completed cleanly
then). pool-overflow, mtls-conflict and noise-only are v0.2 runs with the
transport fixed (paced proxy, zero provider errors): each consumed its full
15-step budget and ended in a max-steps exception with no final answer.
These mistral-large numbers are a lower bound on HolmesGPT: on its own
public eval suite its best model (Claude Sonnet 4) passes 86% and GPT-4o
56%, so investigation quality is strongly model-dependent. Details,
transport disclosure and the citation in
[results/holmesgpt.md](results/holmesgpt.md).

What the numbers actually say: when HolmesGPT completes an investigation,
it is genuinely good — its v0.1 canary diagnosis (reading the injected env
var off the pod spec) was the deepest any tool produced. But across five
scenarios it completed two. The failures are no longer provider 429s: with
a clean paced transport it exhausted its step budget wandering — never
touching `response_flags=UO` in pool-overflow, never touching
PeerAuthentication or ztunnel in mtls-conflict, and never managing to say
"nothing is wrong" on a healthy cluster in noise-only. v0.2 MeshMedic
closes every gap HolmesGPT's good runs exposed (labeled evidence names the
5xx subset; configuration evidence reads the same env vars
deterministically in seconds) and detects the ambient mTLS conflict from
ztunnel's TCP telemetry
(`istio_tcp_connections_closed_total{response_flags="DENY"}`), naming both
the denied client and the STRICT policy. On noise-only, k8sgpt's AI mode
scored below its own no-AI mode: the LLM wrapped harmless findings in
confident error narratives with imperative fixes. The k8sgpt fault-scenario
zeros are still not a k8sgpt bug: its analyzers inspect object state, mesh
incidents leave objects healthy, and an AI backend cannot explain what the
scanner never sees ([results/k8sgpt.md](results/k8sgpt.md)).

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

Each raw output ends with a footer the harness measures itself: the tool's
wall time and an inventory diff of cluster objects created or deleted while
the tool ran. Investigation side effects are part of a tool's cost; a
diagnostic run that spawns test pods in a production namespace mid-incident
is worth knowing about before you page it.

## License

Apache-2.0
