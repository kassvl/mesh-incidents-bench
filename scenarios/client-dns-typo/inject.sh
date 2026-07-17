#!/usr/bin/env bash
set -euo pipefail
# Bad client rollout: repoint loadgen at a Service name that does not exist
# (payments-svc.demo -> NXDOMAIN) so every request fails DNS resolution before
# a socket is opened. Traffic to payments falls to zero and no mesh signal
# fires. loadgen's target lives inline in the container args (there is no URL
# env var to `set env`), so we patch the args and roll it, mirroring the
# set-env + rollout-wait shape of the other scenarios. -sS keeps curl's
# resolver error on stderr so the failure is visible in `kubectl logs`.
kubectl -n demo patch deployment loadgen --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"loadgen","args":["while true; do curl -sS -m 2 -o /dev/null http://payments-svc.demo:9090/; sleep 0.2; done"]}]}}}}'
kubectl -n demo rollout status deploy/loadgen --timeout=120s
