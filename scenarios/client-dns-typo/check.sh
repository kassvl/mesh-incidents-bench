#!/usr/bin/env bash
# Exits 0 while the client DNS misconfiguration is live: the current loadgen
# pod is logging name-resolution failures AND payments' request rate at
# Prometheus has fallen to ~zero (no L7 traffic reaches the mesh at all).
set -euo pipefail

# Gate A: loadgen is actively failing to resolve its target right now. --since
# scopes to the current pod's recent output so a stale success cannot pass.
logs=$(kubectl -n demo logs deploy/loadgen --tail=50 --since=90s 2>/dev/null || true)
if ! grep -Eqi 'could not resolve|couldn.t resolve|resolve host|name or service not known|temporary failure in name resolution' <<<"$logs"; then
  exit 1
fi

# Gate B: payments request rate is below 0.1 rps (traffic has stopped). A
# missing series (nan) also means no traffic, which is the incident condition;
# the residual rate from pre-inject traffic decays out of the [1m] window, so
# this gate only holds once the incident is fully live.
v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments"}[1m]))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
python3 -c "import math; v=float('$v'); exit(0 if math.isnan(v) or v < 0.1 else 1)"
