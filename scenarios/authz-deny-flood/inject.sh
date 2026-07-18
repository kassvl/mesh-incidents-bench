#!/usr/bin/env bash
set -euo pipefail
# A DENY AuthorizationPolicy that rejects the loadgen caller (which has a
# valid mesh identity) at the payments waypoint. Stands in for a DENY rule
# that is broader than intended, or a default-deny gap. loadgen's calls
# start returning HTTP 403 while payments itself stays healthy.
kubectl apply -f - <<'YAML'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payments-block-loadgen
  namespace: demo
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: payments
  action: DENY
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/demo/sa/default"]
YAML
