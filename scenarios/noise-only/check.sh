#!/usr/bin/env bash
# Exits 0 while the scenario is "live": the noise objects exist AND the
# payments service is demonstrably healthy (5xx ratio under 5%). A healthy
# service is this scenario's incident condition; tools are graded on
# leaving it alone.
set -euo pipefail

kubectl -n demo get configmap legacy-feature-flags >/dev/null
kubectl -n demo get service payments-legacy >/dev/null
kubectl -n demo get pod one-off-migration >/dev/null

v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments", response_code=~"5.."}[1m])) / sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments"}[1m]))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
# No 5xx samples at all (nan) also counts as healthy.
python3 -c "import math; v=float('$v'); exit(0 if math.isnan(v) or v < 0.05 else 1)"
