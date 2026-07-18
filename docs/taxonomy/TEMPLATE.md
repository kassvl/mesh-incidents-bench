# Taxonomy candidate template

Each candidate in a `candidates-<slice>.md` file is one failure class,
written in this exact shape so the maintainer can dedup, rank, and queue it
for testbed validation. Do not invent telemetry: if you are unsure what a
fault emits, say so in the "detectable?" field rather than guessing a metric
name.

## <class-name-in-kebab-case>

- **Mechanism**: what misconfiguration or event causes it, and what the mesh
  does in response. One or two sentences.
- **Telemetry signature**: the metric and label(s) that change, or
  explicitly "absence of traffic", or "no mesh signal (needs object/log)".
- **Signal draft (PromQL)**: a first-cut query against the payments testbed,
  or "n/a — object/log evidence only".
- **Inject sketch**: the kubectl/manifest steps to induce it on the payments
  testbed (payments-v1/v2 Deployments, payments Service, loadgen, `demo`
  namespace, Istio ambient). Keep it to what `inject.sh` would run.
- **Triage signatures**: log regexes, object fields, or rollout diffs that
  would appear, if the class is client/config-layer. Otherwise "n/a".
- **Detectable deterministically?**: yes / partial / no, with one clause of
  why. "no" is a valid and useful answer.
- **Overlaps existing catalog?**: name any of the 9 current entries it
  duplicates or extends, or "new".
- **Sources**: Istio GitHub issue URLs, istio.io doc URLs, or HolmesGPT
  fixture names that ground this as a real, observed failure. At least one.
