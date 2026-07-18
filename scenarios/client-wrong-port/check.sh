#!/usr/bin/env bash
# Exits 0 while the client wrong-port incident is live: loadgen is logging
# empty-reply failures AND payments' request rate has fallen to ~zero.
set -euo pipefail
logs=$(kubectl -n demo logs deploy/loadgen --tail=50 --since=90s 2>/dev/null || true)
if ! grep -Eqi 'empty reply|curl: \(52\)|connection reset' <<<"$logs"; then
  exit 1
fi
v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments", destination_service_namespace="demo"}[1m]))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
python3 -c "import math; v=float('$v'); exit(0 if math.isnan(v) or v < 0.1 else 1)"
