#!/usr/bin/env bash
set -euo pipefail
# Bad client rollout: repoint loadgen at payments:9091, a port the service
# does not expose (it listens on 9090). The host resolves and ztunnel
# accepts the TCP connection, but the closed backend port returns an empty
# reply, so every request fails and payments' L7 request rate falls to zero.
# A different signature from the DNS-typo scenario (empty reply vs NXDOMAIN),
# same triage class. -sS keeps curl's error on stderr for the log sweep.
kubectl -n demo patch deployment loadgen --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"loadgen","args":["while true; do curl -sS -m 2 -o /dev/null http://payments:9091/; sleep 0.2; done"]}]}}}}'
kubectl -n demo rollout status deploy/loadgen --timeout=120s
