#!/usr/bin/env bash
set -euo pipefail
kubectl -n demo patch deployment loadgen --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"loadgen","args":["while true; do curl -s -o /dev/null http://payments:9090/; sleep 0.2; done"]}]}}}}'
kubectl -n demo rollout status deploy/loadgen --timeout=120s
