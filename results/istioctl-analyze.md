# istioctl analyze results

The fair mesh-native reference. Earlier versions of this benchmark scored
general Kubernetes tools (HolmesGPT, k8sgpt) that do not target the service
mesh at all; that was a category error, removed. `istioctl analyze` is Istio's
own diagnostic tool, so it is a legitimate same-domain comparison: both it and
MeshMedic read the mesh, and the honest question is what each sees.

- Tool: `istioctl analyze` (Istio 1.24.1), the built-in configuration analyzer
- Date: 2026-07-19, testbed: kind + Istio 1.24 ambient (the MeshMedic demo env)
- Method: run `istioctl analyze -n demo` on the healthy cluster and while each
  fault is live, and record what it reports

## What it is

`istioctl analyze` is a static configuration analyzer. It validates Istio and
Kubernetes objects against a set of analyzers and reports invalid or risky
configuration: a VirtualService that references a subset no DestinationRule
defines, a PeerAuthentication that conflicts with a DestinationRule TLS mode, an
EnvoyFilter using deprecated internals. It runs before or independent of
traffic. It does not read Prometheus, ztunnel, or any runtime telemetry.

## Measured results

| test | istioctl analyze output |
| --- | --- |
| Healthy baseline | `No validation issues found` |
| Config error: VirtualService routes to a non-existent subset `v3` | `Error [IST0101] (VirtualService demo/payments) Referenced host+subset in destinationrule not found: "payments+v3"` |
| Runtime incident: `error-surge` (payments-v2 at ERROR_RATE 0.9, a real 5xx surge) | `No validation issues found` |
| EnvoyFilter present: the `rate-limit-throttling` fault | `Warning [IST0133]` and `[IST0151]`: generic EnvoyFilter hygiene warnings, not a report that traffic is being throttled |

## What the results say

`istioctl analyze` catches configuration that is *invalid* (the IST0101 subset
reference), which is exactly its job and a real, useful check. It is blind to
everything that is *valid configuration behaving badly at runtime*: it reported
no issue during a live 5xx surge, and on the rate-limit fault it warned only
that the EnvoyFilter uses risky internals, not that live traffic was being
rejected with 429.

This is the honest split, and it is complementary, not a contest:

- **`istioctl analyze` is a config-time linter.** It answers "is my Istio
  configuration valid and safe?" before traffic, and catches invalid references
  and mode conflicts. MeshMedic does not do this; a valid but wrong config
  (a route timeout shorter than the backend, a rate limit set too low) passes
  istioctl analyze and is only visible once traffic hits it.
- **MeshMedic is a runtime incident detector.** It answers "what is breaking in
  live traffic right now, and why?" and reads the telemetry istioctl analyze
  never looks at: 5xx surges, latency regressions, outlier ejection, connection
  pool overflow, dependency failures, rate-limit and ext-authz denials. Of the
  catalog's classes, the only ones istioctl analyze could also flag are the few
  that are genuine configuration-validity errors; the runtime classes (latency,
  errors, ejection, throttling, dependency-layer) are outside what a static
  analyzer can see.

The takeaway is the same as with the general Kubernetes tools, but here it is
between two mesh-native tools rather than across domains: run `istioctl analyze`
in CI to keep the config valid, and run MeshMedic against live telemetry to
catch what a valid config does under real traffic. Neither replaces the other.
