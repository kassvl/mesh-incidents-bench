#!/usr/bin/env bash
set -euo pipefail
# Bad client rollout: loadgen speaks https to payments, which serves plain
# HTTP. The TLS handshake gets an HTTP response and fails (curl 35), every
# call fails, and payments' L7 request rate falls to zero. Same triage class
# as the DNS typo and wrong port, a third distinct signature (TLS error).
kubectl -n demo patch deployment loadgen --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"loadgen","args":["while true; do curl -sS -m 2 -o /dev/null https://payments:9090/; sleep 0.2; done"]}]}}}}'
kubectl -n demo rollout status deploy/loadgen --timeout=120s
