#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo scale deploy/loadgen --replicas=1
kubectl -n demo set env deploy/payments-v1 TIMING_50_PERCENTILE=20ms
kubectl -n demo set env deploy/payments-v2 TIMING_50_PERCENTILE=20ms
kubectl -n demo patch destinationrule payments --type json \
  -p '[{"op": "remove", "path": "/spec/trafficPolicy"}]' 2>/dev/null || true
kubectl -n demo rollout status deploy/payments-v1 deploy/payments-v2 --timeout=120s
