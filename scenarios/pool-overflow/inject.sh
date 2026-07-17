#!/usr/bin/env bash
set -euo pipefail
# Slow the server and multiply the load so requests stack up, then clamp the
# connection pool to one connection. The circuit breaker starts shedding.
kubectl -n demo set env deploy/payments-v1 TIMING_50_PERCENTILE=300ms
kubectl -n demo set env deploy/payments-v2 TIMING_50_PERCENTILE=300ms
kubectl -n demo scale deploy/loadgen --replicas=8
kubectl -n demo patch destinationrule payments --type merge -p '{
  "spec": {"trafficPolicy": {"connectionPool": {
    "tcp": {"maxConnections": 1},
    "http": {"http1MaxPendingRequests": 1, "http2MaxRequests": 1}
  }}}}'
kubectl -n demo rollout status deploy/payments-v1 deploy/payments-v2 --timeout=120s
