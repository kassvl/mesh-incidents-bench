# HolmesGPT results

- Tool: HolmesGPT 0.36.0 (`holmes ask`, same hint-free prompt per scenario,
  `--max-steps 15`), model: mistral/mistral-large-latest
- Key tier: Mistral experiment (4 requests/min, 250K tokens/min), routed
  through the harness throttle proxy after early runs died on 429s
- Date: 2026-07-17, testbed: kind + Istio 1.24 ambient, single node
- Raw output: `raw/*-run-holmesgpt*.txt`

| scenario | detection | diagnosis | remediation | total |
| --- | --- | --- | --- | --- |
| canary-latency | 2 | 2 | 2 | 6 |
| error-surge | 2 | 2 | 1 | 5 |
| pool-overflow | not scored: provider limits | | | |
| mtls-conflict | not scored: provider limits | | | |
| **scored total** | | | | **11 / 12** |

## Notes per scenario

- **canary-latency**: full marks, and the deepest diagnosis any tool
  produced on this scenario. It read the pod configuration, named the
  injected `TIMING_50_PERCENTILE: 1200ms` on `payments-v2` as the root
  cause, contrasted it with v1's ~20ms, and offered the VirtualService
  route-to-v1 patch among its fixes. Runtime was around nine minutes under
  request pacing, versus seconds for a deterministic watcher, which is the
  trade this benchmark makes visible rather than judges.
- **error-surge**: found the injected `ERROR_RATE=0.9` on `payments-v2` and
  recommended removing it. Remediation scored 1, not 2, because its
  first-listed fix addressed unrelated `Unauthorized` event noise in the
  testbed (disclosed in results/k8sgpt.md) rather than the incident.
- **pool-overflow, mtls-conflict**: two attempts each ended in Mistral 429s
  despite 16s request pacing; HolmesGPT's context grows past the tier's
  250K tokens/minute as an investigation deepens. These are limits of the
  key tier, not findings about the tool, so the scenarios are reported as
  not scored. Reruns with a better-provisioned key are welcome as PRs.

## Operational notes

Three earlier unthrottled runs died mid-investigation on 429s, and one hung
for hours ignoring SIGTERM (the harness now escalates to SIGKILL). Agentic
investigators inherit the failure modes of their LLM provider; a paged
operator would have experienced all of them. The raw logs, including the
invalidated runs, are kept in `raw/`.
