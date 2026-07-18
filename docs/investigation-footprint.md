# Investigation footprint: what a diagnostic tool does to the cluster while it investigates

Diagnostic tools are usually compared on whether they find the root cause,
how long they take, and what they cost in tokens. One axis is rarely
measured: how much the tool changes the cluster while investigating. An
agent that spawns pods, execs into containers, or applies objects to test a
hypothesis is mutating the same system it is diagnosing, often in the exact
namespace that is already having an incident. This benchmark instruments
that axis and calls it the investigation footprint.

## Definition and how the harness measures it

Investigation footprint is the set of cluster objects a tool creates or
deletes during its run. The harness measures it directly, with no
cooperation from the tool under test. Before the tool starts and again
after it finishes, `harness/run.sh` snapshots the object inventory:

```
kubectl get pods,services,configmaps,deployments,jobs,secrets -A -o name | sort
```

The difference between the two snapshots is written into every raw output's
footer:

```
# tool_wall_seconds: 461
# cluster_objects_created_during_run: 0
# cluster_objects_deleted_during_run: 0
# created: pod/demo/dns-test
# deleted: ...
```

This counts object inventory only. It does not count in-place interactions
such as `kubectl exec` into a running pod, which mutate state inside a
container without changing the inventory; those are a separate category,
noted below.

## Why it matters: an observed example

The motivating case is HolmesGPT's v0.1 canary-latency run. While trying to
reach Prometheus and test connectivity, it created five throwaway pods in
the `demo` namespace, the namespace under investigation, via `kubectl run`:

```
kubectl run dns-test    -n demo --image=busybox:1.35 ...
kubectl run curl-test   -n demo ...   (four times)
kubectl run netcat-test -n demo --image=alpine:3.18 ...
```

It also ran `kubectl exec` into the Prometheus pod. None of this is
malicious or unusual for an agentic tool; probing connectivity by launching
a pod is a reasonable thing for a human operator to do too. But a tool that
does it automatically, during an incident, in the affected namespace, is
adding load and objects to a system that is already degraded, and a paged
operator inherits the cleanup. That is a real cost, and until it is
measured it is invisible in every "did it find the bug" comparison.

## What the instrumented runs show

The footer was added in the v0.2 harness (commit `dd68e82`), after the v0.1
canary run above, so that run's footprint is documented from its tool-call
log rather than the footer. Every v0.2 run carries the footer. The measured
result across those runs:

| tool | object footprint (v0.2 runs) | notes |
| --- | --- | --- |
| MeshMedic | 0 created, 0 deleted, every run | structural: it never writes to the cluster; its only side effect is a GitOps pull request |
| HolmesGPT (mistral) | 0 created, 0 deleted, every run | these runs stayed read-only; the mtls run did `kubectl exec` into the Prometheus pod (not counted as an object change) |
| k8sgpt | 0 created, 0 deleted | read-only analyzers by design |

The honest reading of this table is not "HolmesGPT mutates the cluster." In
these particular runs it did not create objects. The point is subtler and
more durable:

- **MeshMedic's zero is a design guarantee.** It has no code path that
  writes to the cluster. Its remediation output is a pull request against
  the config repository, reviewed and merged by a human; the cluster is
  changed by GitOps, not by MeshMedic. The zero holds on every run, on
  every scenario, by construction.
- **An agent's zero is per-run.** The v0.1 canary run created five pods;
  the v0.2 runs created none. Same tool, different model decisions,
  different footprint. Whether a given investigation mutates the cluster
  depends on what the model chooses to do that time, which is exactly why
  it is worth measuring rather than assuming.

## Interactions the object footer does not catch

`kubectl exec` runs commands inside an existing pod without changing the
object inventory, so it does not appear in the created/deleted counts.
HolmesGPT used it against the Prometheus pod in both a v0.1 and a v0.2 run.
It is a lighter-weight interaction than creating a pod, but it is still the
diagnostic tool reaching into a running workload. A future harness revision
could count exec and port-forward invocations from the tool-call log; for
now they are disclosed here rather than scored.

## Using it

The footer is produced automatically for any tool the harness runs, so
comparing footprint across tools requires no extra work: run each tool
through `harness/run.sh` and read the last lines of its raw output. A tool
that spawns objects during a run leaves them named in the `# created:`
line, so the footprint is auditable, not just a count.
