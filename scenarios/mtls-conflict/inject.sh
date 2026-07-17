#!/usr/bin/env bash
set -euo pipefail
# STRICT mTLS on the namespace plus a plaintext client outside the mesh.
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: demo-strict
  namespace: demo
spec:
  mtls:
    mode: STRICT
EOF
kubectl -n default run plain-client --image=curlimages/curl:8.11.1 \
  --restart=Never -- sh -c 'while true; do curl -s -m 2 -o /dev/null http://payments.demo:9090/ ; sleep 1; done' 2>/dev/null || true
kubectl -n default wait --for=condition=Ready pod/plain-client --timeout=120s
