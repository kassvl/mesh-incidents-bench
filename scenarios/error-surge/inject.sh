#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo set env deploy/payments-v2 ERROR_RATE=0.9 ERROR_CODE=500
kubectl -n demo rollout status deploy/payments-v2 --timeout=120s
