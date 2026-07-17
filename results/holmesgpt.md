# HolmesGPT results

- Tool: HolmesGPT 0.36.0 (`holmes ask`, same hint-free prompt per scenario,
  `--max-steps 15`), model: mistral-large-latest
- Key tier: Mistral experiment, routed through the harness throttle proxy
- Date: 2026-07-17/18 (v0.1 + v0.2 runs), testbed: kind + Istio 1.24
  ambient, single node
- Raw output: `raw/*-run-holmesgpt*.txt`

## v0.2 combined scorecard

| scenario | detection | diagnosis | remediation | total | run |
| --- | --- | --- | --- | --- | --- |
| canary-latency | 2 | 2 | 2 | 6 | v0.1 |
| error-surge | 2 | 2 | 1 | 5 | v0.1 |
| pool-overflow | 0 | 0 | 0 | 0 | v0.2 retry |
| mtls-conflict | 0 | 0 | 0 | 0 | v0.2 retry |
| noise-only | 1 | 0 | 2 | 3 | v0.2 |
| **total** | | | | **14 / 30** |

## v0.2 retries (2026-07-18)

The v0.1 pool-overflow and mtls-conflict runs were "not scored" because the
key tier's 429s killed the investigations: a provider failure, not a tool
finding. For v0.2 the transport was fixed and the retries completed cleanly,
so they are scored.

**Transport disclosure**: current litellm ignores `MISTRAL_API_BASE` for
the `mistral/` provider, so the paced proxy is reached through litellm's
OpenAI-compatible route (`openai/mistral-large-latest` — the upstream model
is unchanged). The proxy paces one request per 30s and strips the
OpenAI-only message bookkeeping fields (`provider_specific_fields`,
`refusal`) that Mistral's API rejects with 422. Raw logs of the transport
failures that motivated this (429 burst, env var ignored, 422 schema
rejection) are kept in `raw/` unedited. In all three v0.2 runs there were
zero provider errors; nothing below is a rate-limit artifact.

- **pool-overflow (0/6)** and **mtls-conflict (0/6)**: both runs consumed
  the full 15-step budget and ended in `Exception: Too many LLM calls -
  exceeded max_steps: 15/15` without producing a final answer (~460s wall
  each). The same 15-step budget was enough for its v0.1 full-marks canary
  run, so the cap is not the story: the investigations wandered. In
  pool-overflow it reached VirtualService/DestinationRule reads but never
  landed on the `response_flags=UO` signal; in mtls-conflict, 45 tool calls
  included essentially no contact with PeerAuthentication, ztunnel, or any
  mTLS concept — the L4 blindness the scenario probes held even with a
  working key. A paged operator gets an exception after eight minutes.
- **noise-only (3/6)**: no false incident was claimed (detection 1) and no
  fix proposed (remediation 2), but after 25 tool calls across a healthy
  namespace it never delivered the all-clear either: the run ended in the
  same max-steps exception with no answer of any kind (diagnosis 0).
  Knowing when to stop is the skill this scenario measures.
- **Side effects, measured**: unlike the v0.1 canary run (test pods created
  mid-incident via `kubectl run`), all three v0.2 runs created and deleted
  zero cluster objects — though the mtls run did `kubectl exec -it` into a
  payments pod during the incident.

## Context: HolmesGPT's own published evaluations

The obvious objection to the scores above is the model: mistral-large on a
free key is not HolmesGPT at its best. Rather than paying to rerun with a
frontier model, we cite HolmesGPT's own published eval results as the
upper-bound context. The project maintains a public evaluation framework
(holmesgpt.dev → Development → Evaluations) with dated multi-model runs.
Their 2025-10-12 comparison across 105 of their own test cases: Claude
Sonnet 4 (their best) 86% pass, DeepSeek v3.1 79%, GPT-5 79%, GPT-4.1 71%,
GPT-4o 56% — and in their "chain-of-causation" category GPT-4o and GPT-4.1
scored 0% while Claude reached 71%. Two takeaways for reading our table:
our mistral runs are a lower bound on HolmesGPT, and even on its home
benchmark with its best model it does not clear everything — investigation
quality is strongly model-dependent. A frontier-model rerun on this bench
remains welcome as a PR.

## v0.1 notes (unchanged)

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
