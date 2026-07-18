#!/usr/bin/env bash
# Exits 0 while payments is returning UT (upstream timeout) flagged responses.
set -euo pipefail
v=$(curl -sf "http://127.0.0.1:9090/api/v1/query" --data-urlencode \
  'query=sum(rate(istio_requests_total{reporter="waypoint", destination_service_name="payments", destination_service_namespace="demo", response_flags="UT"}[1m]))' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")')
python3 -c "import math; v=float('$v'); exit(0 if not math.isnan(v) and v > 0.5 else 1)"
