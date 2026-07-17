# k8sgpt results

- Tool: k8sgpt (`k8sgpt analyze --namespace demo`), run twice per scenario:
  without an AI backend, and with `--explain` through an OpenAI-compatible
  endpoint (model: mistral-large-latest)
- Date: 2026-07-17, testbed: kind + Istio 1.24 ambient, single node
- Raw output: `raw/*-k8sgpt-*.txt` (no AI), `raw/*-run-k8sgpt-ai*.txt` (AI)

| scenario | detection | diagnosis | remediation | total |
| --- | --- | --- | --- | --- |
| canary-latency | 0 | 0 | 0 | 0 |
| error-surge | 0 | 0 | 0 | 0 |
| pool-overflow | 0 | 0 | 0 | 0 |
| mtls-conflict | 0 | 0 | 0 | 0 |
| **total** | | | | **0 / 24** |

## Notes

In every run, with the incident live and confirmed observable by the
harness, `k8sgpt analyze` reported the same findings: empty ConfigMaps,
unused `kube-root-ca.crt` entries, and an Argo CD StatefulSet service-name
false positive. Nothing about the `payments` workload in any scenario.

This is not a bug in k8sgpt. Its analyzers inspect Kubernetes object state
(pod status, events, probes, quotas), and every mesh incident here leaves
the objects healthy: pods Running, probes green, deployments available.
The failure lives entirely in the telemetry layer the mesh emits. That gap
between object health and traffic health is exactly what this benchmark
measures. A k8sgpt custom analyzer that reads mesh metrics would close it.

## AI mode changes nothing

The AI-backed runs (`--explain`, mistral-large-latest) scored identically:
0 across the board. The model wrote clearer explanations and fix steps for
what the analyzers surfaced, but the analyzers still only surfaced object
state, so every scenario produced the same two findings regardless of
which fault was live. The LLM cannot explain what the scanner never sees.

**Testbed contamination note**: during these runs the cluster briefly
logged real `Unauthorized` endpoint-update events (a kind token hiccup
after host sleep, unrelated to any scenario). Both k8sgpt modes surfaced
and explained those events. They were environmental noise, disclosed here;
they did not change any score in either direction.
