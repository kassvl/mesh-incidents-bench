# Agent comparison: method and participant setup

**Status: method fixed, runs not yet executed.** This document is written
before the measurement so the setup cannot be tuned to the result. Nothing
below reports a finding; it reports what will be done and, in one section,
what was verified about the tooling.

The question is:

> What does a diagnostic agent do to a live cluster while it investigates an
> incident, and does it get the answer right?

The accuracy half is contested and biased. The cost half is neither, and it is
the half nobody has published.

## Participants

| id | tool | write access |
| --- | --- | --- |
| A | MeshMedic | none, structural |
| B1 | Kiali MCP + LLM, no runbook | Istio config write available |
| B2 | Kiali MCP + LLM, given the compiled catalog runbook | same as B1 |
| C | LLM agent with kubectl | full, RBAC-scoped to the testbed namespace |

B2 is the experiment that matters most. If B2 substantially outperforms B1,
the catalog is valuable independent of the detector that reads it, which is
the empirical claim behind compiling the taxonomy to targets that do not need
MeshMedic at all. It costs one extra run condition.

## Tooling verification (2026-08-19)

The plan assumed the Kiali MCP server might ship in a `kubernetes` and an
`openshift` variant, with the write-capable Istio config tooling only on the
OpenShift path. If that were true, condition B could not be write-capable on
kind and would collapse to a read-only comparison.

**It is not true, and the setup is simpler than feared.** Verified against the
upstream project documentation:

- There is **no kubernetes-versus-openshift split at the tool level**. One
  codebase (`containers/kubernetes-mcp-server`, mirrored as
  `openshift/openshift-mcp-server`) serves both, and nothing restricts the
  Kiali toolset to OpenShift.
- The Kiali toolset exposes a write tool, `kiali_manage_istio_config`,
  alongside its read counterpart `kiali_manage_istio_config_read`, plus
  `kiali_get_mesh_status`, `kiali_get_mesh_traffic_graph`,
  `kiali_get_resource_details`, `kiali_get_metrics`, `kiali_get_logs`,
  `kiali_list_traces`, `kiali_get_trace_details`,
  `kiali_get_pod_performance`, and `kiali_list_mesh_clusters`.
- **The Kiali toolset is not enabled by default.** Only `config` and `core`
  are. It must be requested explicitly with `--toolsets` (or the `toolsets`
  TOML key). A run that forgets this measures a general Kubernetes agent, not
  a mesh-aware one, and would silently be the wrong experiment.
- Write is gated by **operational flags, not by platform**: `--read-only`
  (TOML `read_only`) and `--disable-destructive`. Both default to off, so
  write is available unless it is switched off.
- It runs via `npx kubernetes-mcp-server@latest`, so kind is fine.

**Consequence:** condition B stays write-capable. The fallback that would have
promoted C to sole write-capable participant is not needed, and B1 versus B2
survives intact.

## A fairness point this verification creates

Because write access for B is a flag rather than a property, the method must
state plainly that B1, B2 and C are run **without** `--read-only` and
**without** `--disable-destructive`. Otherwise a reader is entitled to assume
the footprint numbers are an artifact of how the agents were configured.

Stating it makes the headline claim stronger, not weaker, because it sharpens
what the comparison is actually about:

- **MeshMedic's zero footprint is structural.** It holds no cluster write
  credentials at all. There is no flag to flip, and no configuration in which
  it mutates a cluster.
- **An agent's footprint is a policy decision.** It can be zero, if someone
  remembers to set `--read-only`, keeps it set, and accepts that the agent can
  then no longer act on what it finds.

That is the honest difference, and it is a more interesting result than a
scoreboard: the question is not whether an agent *can* be made safe, but what
it does when it is configured the way its own documentation configures it by
default.

## Axes

1. Detection (0-2), per the scenario's `ground-truth.md` rubric
2. Diagnosis (0-2)
3. Remediation (0-2)
4. Wall time
5. **Investigation footprint**: cluster objects created, deleted and mutated
   during the run, measured by the harness, not self-reported
6. **Write attempts**: did the tool try to mutate state, and was it permitted

## Fairness controls

- **Axes 1-3 are a home game for A.** MeshMedic was developed against these
  exact scenarios; B and C have never seen them. Disclosed per scenario, as
  `results/meshmedic.md` already does. These numbers do not lead.
- **Axes 5-6 carry no author bias.** MeshMedic's zero comes from holding no
  credentials, not from being good at these particular scenarios. This is the
  headline.
- **3 runs per agent condition per scenario**, with variance reported. Agents
  are non-deterministic. MeshMedic's variance is 0 by construction, which is
  itself a result and is stated as one rather than as a win.
- Identical inputs across conditions: same Prometheus, same namespace scope,
  same incident window.
- Every write-capable agent runs against RBAC scoped to the testbed namespace
  on kind. Never anything real.

## Sampling

The full matrix is 11 scenarios x 4 conditions x 3 runs, about 132 runs, which
does not fit the window. The full matrix runs on six scenarios chosen for
diversity of signal type:

| scenario | why it is in the sample |
| --- | --- |
| `error-surge` | L7 error signal, the common case |
| `canary-latency` | latency rather than errors |
| `mtls-conflict` | ambient L4, invisible to request metrics |
| `client-dns-typo` | absence-based; the tool's own recorded miss |
| `noise-only` | false-positive control |
| `route-timeout-too-short` | config accident, valid config behaving wrongly |

The remaining five get one run per condition as a spot check. The sampling is
stated in the writeup rather than left to be discovered.

`noise-only` is mandatory in the sample. An agent that "finds" a root cause in
a healthy cluster is the most damning single result available, and it is the
axis every fault scenario is structurally blind to.
