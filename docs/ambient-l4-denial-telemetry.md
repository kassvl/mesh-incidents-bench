# Detecting ambient strict-mTLS denials from ztunnel L4 telemetry

A practical reference for finding, in Prometheus, the connections that
ztunnel rejects at layer 4 in an Istio ambient mesh. This is the signal
behind the `mtls-conflict` scenario in this benchmark, where every
request-metric-based tool scored zero.

Verified on Istio / ztunnel 1.24.1, ambient mode, kind single node. Label
sets and log lines below are copied from a live cluster, not reconstructed.

## The problem: the rejection never becomes a request

In ambient mode a client without mesh identity (no sidecar, not enrolled)
that calls a STRICT-mTLS workload is rejected by ztunnel during connection
setup. The connection is refused before any L7 request is parsed, so it
never increments `istio_requests_total` or any of the request-duration or
response-code series that most mesh dashboards and troubleshooting tools
watch. Request-based monitoring stays green while the client fails every
call. The signal exists one layer down, in ztunnel's TCP connection
telemetry.

## The signal: `istio_tcp_connections_closed_total` with `response_flags="DENY"`

ztunnel exports TCP connection counters. A policy-rejected connection is
recorded as closed with a `DENY` response flag and, because the client had
no verifiable identity, a `connection_security_policy` of `unknown`.

Grouping the closed-connection counter for one destination service makes
the rejected traffic stand out from healthy traffic:

```
sum by (source_workload, connection_security_policy, response_flags)
  (istio_tcp_connections_closed_total{destination_service_name="payments"})
```

On a cluster where a plaintext `plain-client` is being rejected while the
mesh's own workloads talk normally, this returns:

| source_workload | connection_security_policy | response_flags | connections |
| --- | --- | --- | --- |
| waypoint | mutual_tls | `-` | 57402 |
| loadgen | mutual_tls | `-` | 69050 |
| plain-client | unknown | **DENY** | 1134 |

Healthy in-mesh traffic is `mutual_tls` with an empty response flag. The
rejected client is `unknown` / `DENY`. The `DENY` flag is the reliable
discriminator: `connection_security_policy="unknown"` alone also appears on
a small number of non-denied connections during setup, so match on the
flag.

### The full label set of a denial series

Every label on one rejected series, for reference when writing selectors:

```
istio_tcp_connections_closed_total{
  reporter="destination",
  response_flags="DENY",
  connection_security_policy="unknown",
  request_protocol="tcp",
  source_workload="plain-client",
  source_workload_namespace="default",
  source_principal="unknown",
  destination_workload="payments-v1",
  destination_service_name="payments",
  destination_service_namespace="demo",
  destination_principal="spiffe://cluster.local/ns/demo/sa/default",
  app="ztunnel", namespace="istio-system", pod="ztunnel-...",
  ...
}
```

Two labels carry the diagnosis on their own: `response_flags="DENY"` says
the connection was rejected by policy, and `source_principal="unknown"`
says the caller had no mesh identity, which is exactly the strict-mTLS vs
identity-less-client conflict.

### A detection query

A rate over the denial series, aggregated per destination service, is a
usable alert signal. This is the form the MeshMedic catalog uses:

```
sum(rate(istio_tcp_connections_closed_total{
  reporter="destination",
  destination_service_name="payments",
  destination_service_namespace="demo",
  response_flags="DENY"
}[2m]))
```

To name the rejected callers in a report, group the same series by source:

```
sum by (source_workload, source_workload_namespace, source_principal)
  (rate(istio_tcp_connections_closed_total{
    reporter="destination",
    destination_service_name="payments",
    destination_service_namespace="demo",
    response_flags="DENY"
  }[5m]))
```

## Where ztunnel exposes it

ztunnel serves metrics on port `15020`. The default ambient install ships
the ztunnel DaemonSet with the standard scrape annotations, so the stock
Istio Prometheus addon already collects these series with no extra
configuration:

```
prometheus.io/scrape: "true"
prometheus.io/port: "15020"
```

Confirm the target is being scraped:

```
kubectl -n istio-system get pod -l app=ztunnel \
  -o jsonpath='{.items[0].metadata.annotations.prometheus\.io/port}'
```

Related ztunnel TCP series, if you need bytes or open-connection counts:
`istio_tcp_connections_opened_total`, `istio_tcp_received_bytes_total`,
`istio_tcp_sent_bytes_total`.

## The access-log alternative

If you are not scraping ztunnel, the same rejection is in its access log.
Every denied connection logs a `connection complete` line at `error` level
with zero bytes transferred, zero duration, and a policy-rejection message
that names the enforcing PeerAuthentication:

```
error access connection complete
  src.workload="plain-client" src.namespace="default"
  dst.service="payments.demo.svc.cluster.local"
  bytes_sent=0 bytes_recv=0 duration="0ms"
  error="connection closed due to policy rejection:
         explicitly denied by: istio-system/istio_converted_static_strict"
```

```
kubectl -n istio-system logs ds/ztunnel --since=2m | grep 'policy rejection'
```

The metric is better for alerting; the log line is better for a one-off
confirmation and for naming the exact policy.

## Reproducing it

STRICT PeerAuthentication on an ambient namespace plus a plaintext caller
from outside the mesh:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: demo-strict
  namespace: demo
spec:
  mtls:
    mode: STRICT
```

```
kubectl -n default run plain-client --image=curlimages/curl:8.11.1 \
  --restart=Never -- sh -c \
  'while true; do curl -s -m 2 -o /dev/null http://payments.demo:9090/; sleep 1; done'
```

Within a minute the `DENY` series appears for `source_workload="plain-client"`.

## Version notes

Metric names, labels, and access-log format are from ztunnel 1.24.1. ztunnel
is a fast-moving component; treat the exact label set as version-specific
and re-verify against your own build. The shape of the signal (a policy
denial surfacing at L4 rather than L7) is inherent to how ambient enforces
mTLS and is not expected to change.
