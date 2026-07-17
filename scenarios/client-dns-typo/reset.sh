#!/usr/bin/env bash
set -euo pipefail
# Restore the loadgen target to the real Service name, exactly as payments.yaml
# ships it, and wait for the good pod to take over.
kubectl -n demo patch deployment loadgen --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"loadgen","args":["while true; do curl -s -o /dev/null http://payments:9090/; sleep 0.2; done"]}]}}}}'
kubectl -n demo rollout status deploy/loadgen --timeout=120s
