#!/usr/bin/env bash
# Exits 0 while the 5xx ratio for payments is above the 15% threshold.
set -euo pipefail
v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments", response_code=~"5.."}[1m])) / sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments"}[1m]))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
python3 -c "import math; v=float('$v'); exit(0 if not math.isnan(v) and v > 0.15 else 1)"
