#!/usr/bin/env bash
# Exits 0 while the canary p99 regression is observable in Prometheus.
set -euo pipefail
v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{reporter="waypoint", destination_service_name="payments", destination_version="v2"}[1m])))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
python3 -c "import math; v=float('$v'); exit(0 if not math.isnan(v) and v > 1000 else 1)"
