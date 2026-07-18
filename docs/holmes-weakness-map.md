# Holmes weakness map - from HolmesGPT's own published eval data

Source: HolmesGPT's public evaluation results (holmesgpt.dev → Development →
Evaluations → history, run of 2025-10-12; six models, 105 test cases). All
numbers below are theirs, not ours. The point of this document: use their
own measurements to decide where a deterministic-first tool can be
structurally better, and record the reasoning.

## Their per-category results (best model / worst model pass rate)

| category | best | worst | reading |
| --- | --- | --- | --- |
| chain-of-causation | 71% (claude-sonnet-4) | **0%** (gpt-4o, gpt-4.1) | Their hardest reasoning class even for frontier models |
| hard | 80% | 20% | Multi-step investigations |
| context_window | 86% | **14%** | Fails when evidence exceeds what the agent can hold |
| traces | 80% | **0%** | Distributed-trace reasoning |
| port-forward | 67% | 22% | Tool/plumbing tasks |
| logs | 74% | 46% | Finding the needle in log noise |
| prometheus | 100% | **25%** | Query-writing is model-dependent |
| medium | 84% | 40% | |
| kubernetes | 85% | 49% | |
| easy / counting / numerical / question-answer | ~100% | 75-100% | Solved classes |

## Where their weak categories are our structural strengths

| their weak category | why we can be structurally better | our status |
| --- | --- | --- |
| **chain-of-causation** (0-71%) | A deterministic dossier *is* a causation chain: rollout diff → traffic stop → caller attribution, each link a re-runnable query. No model has to reconstruct the chain; the engine assembles it. | Triage layer built (rollout-diff + log-sweep + absence signal); mesh chains covered by catalog |
| **context_window** (14-86%) | We never put raw telemetry in a context window. Evidence is pre-filtered (labeled queries, matched log lines only, template diffs only). The failure mode does not exist in this architecture. | Structural - already true |
| **prometheus** (25-100%) | Query-writing variance disappears when queries are curated catalog artifacts reviewed by humans, not generated per-incident. | Structural - already true |
| **logs** (46-74%) | Signature-based sweep reads only pattern-matched lines; no needle-in-haystack step. Ceiling: unknown signatures stay invisible (disclosed trade). | Triage layer built |
| **hard / medium** (20-84%) | Partially reachable: the deterministic slice of "hard" is the chain-of-causation + config-change slice. Open-ended halves stay theirs. | Partial by design |

## Where we should NOT chase them (recorded so we don't drift)

- **question-answer / conversational**: MeshMedic has no ask interface and
  should not grow one to chase this row; it is a different product shape.
- **easy / counting / generic kubectl lookups**: solved by every model;
  zero differentiation.
- **traces / datadog / runbooks-following**: integration surfaces outside
  the mesh wedge; revisit only if users ask.

## Fixture-corpus mining (tests/llm, 266 cases, mined 2026-07-18)

**Corpus scope (re-audited 2026-07-19): all 266 `test_ask_holmes` fixtures are
plain Kubernetes. Zero are Istio or service-mesh scenarios** (no VirtualService,
DestinationRule, PeerAuthentication, waypoint, ztunnel, canary weights, or
response-flag incidents). The only two fixtures whose name contains "traffic"
are `network_policy_blocking_traffic`, which is a CNI NetworkPolicy, not mesh
traffic. This is the honest boundary: Holmes and MeshMedic operate in different
domains. Holmes targets general Kubernetes and observability troubleshooting
(pods, logs, traces, databases, image pulls); MeshMedic targets the Istio
telemetry layer Holmes does not test at all. There is no fixture on which the
two genuinely compete, so "MeshMedic beats Holmes" is not a well-formed claim;
the honest one is that MeshMedic covers a layer general Kubernetes tools do not.
The bench measures mesh-incident diagnosis, a capability Holmes does not target,
which is the deeper reason Holmes wanders on the mesh scenarios rather than a
failure to find a signal it was looking for.

Tag distribution of their own corpus: kubernetes 91, logs 55, hard 42,
question-answer 60, network 15, chain-of-causation 15, prometheus 16.
The `network` and `chain-of-causation` slices - their weakest measured
categories - decompose into concrete failure classes:

| their fixture family | count | deterministic-detectable? | our status |
| --- | --- | --- | --- |
| DNS resolution failures (`42_dns_issues_*`) | 1 scenario, 7 tool-config variants | The mechanism is a `default-deny-egress` NetworkPolicy blocking DNS in a non-mesh namespace, verified by reading the fixture manifest | **Not covered, and out of domain**: no Istio in the fixture, so no mesh telemetry for MeshMedic to read. This corrects an earlier optimistic "covered" note; the fixture is plain-K8s NetworkPolicy, which is Holmes's lane |
| NetworkPolicy blocking traffic (`84`, `176`) | 2 | Yes: traffic vanished + "recently created NetworkPolicy" object evidence | Candidate - needs CNI-enforcing testbed note |
| Misconfigured ingress/gateway class (`25`) | 1 | Yes: gateway object evidence + 404/NR flag signal | Candidate |
| Dependency down → latency/errors (`22`, `156`) | 2 | Partially: destination-scoped upstream error attribution | Candidate (extends error-surge) |
| Cascading failures (`68`) | 1 | Yes: suppression + caller attribution already model this | Covered in part (suppresses) |
| Network flapping (`75`) | 1 | Harder: needs variance/flap detection over time | Research candidate |
| Traces/APM-dependent chains (`114-124`, newrelic/datadog) | ~10 | No - APM integration surface, out of wedge | Deliberately skipped |

Reading: their weakest categories are DNS, network policy, and bad-config
classes. These *inspired* mesh-and-client analogues in our taxonomy (a
client-side DNS failure became `client-dns-typo`, a routing miss became
`no-route-blackhole`), but the fixtures themselves are plain Kubernetes and
MeshMedic does not run against them. The corpus is a source of real failure
*ideas* to reproduce mesh-side, not a set of scenarios MeshMedic covers. Their
corpus is their lane; the mesh analogue is ours.

## How this feeds the taxonomy pipeline

Their fixture corpus (tests/llm in the HolmesGPT repo, public) is a curated
list of problems SREs actually hit, each with ground truth. Mining it as
*input* to our scenario/catalog taxonomy - filtered to classes that are
deterministic-detectable and mesh-or-client-layer - grounds the taxonomy in
observed reality instead of imagination. Fixture-derived candidates still
go through the same gate as everything else: inject on the testbed, observe
the real signal, only then become catalog entries or bench scenarios.
